import Synchronization

struct RingBufferWriteResult: Equatable, Sendable {
    var writtenFrames: Int
    var droppedInputFrames: Int
}

// Single producer and single consumer. Capture owns writeFrame; playback owns readFrame,
// including reset and trimming. Release/acquire cursor publication keeps the producer from
// reusing samples until playback has finished copying them, and hides uncommitted writes.
final class RealtimeAudioRingBuffer: @unchecked Sendable {
    private static let maximumChannelCount = 256
    private static let maximumStorageSampleCount = 1_048_576

    let channelCount: Int
    let capacityFrames: Int

    private let storageFrameCapacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let readFrame = Atomic<Int>(0)
    private let writeFrame = Atomic<Int>(0)
    // These monotonic positions count frames committed to storage. Reads, trims, and
    // resets advance the read side, so a consumer can tell when a captured frame has left the ring.
    private let nextReadFrameSequence = Atomic<UInt64>(0)
    private let nextWriteFrameSequence = Atomic<UInt64>(0)

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = min(max(channelCount, 1), Self.maximumChannelCount)
        let maximumStorageFrameCapacity = Self.maximumStorageSampleCount / self.channelCount
        self.capacityFrames = min(max(capacityFrames, 2), maximumStorageFrameCapacity - 1)
        self.storageFrameCapacity = self.capacityFrames + 1
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: self.channelCount * self.storageFrameCapacity)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    /// Discards currently published frames on the consumer thread and returns their count.
    func reset() -> Int {
        trimToLatestFrames(0)
    }

    @discardableResult
    func writeInterleaved(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: Int,
        sourceChannelCount: Int
    ) -> RingBufferWriteResult {
        let sourceChannelCount = max(sourceChannelCount, 1)
        let requestedFrames = min(frameCount, samples.count / sourceChannelCount)
        guard requestedFrames > 0 else {
            return RingBufferWriteResult(writtenFrames: 0, droppedInputFrames: 0)
        }

        let write = writeFrame.load(ordering: .relaxed)
        let read = readFrame.load(ordering: .acquiring)
        let availableFrames = capacityFrames - occupancyFrames(read: read, write: write)
        let framesToWrite = min(requestedFrames, availableFrames)
        guard framesToWrite > 0 else {
            return RingBufferWriteResult(writtenFrames: 0, droppedInputFrames: requestedFrames)
        }

        if sourceChannelCount == channelCount,
           let source = samples.baseAddress {
            copyIntoStorage(
                source: source,
                storageFrame: write,
                frameCount: framesToWrite
            )
        } else {
            var storageFrame = write
            for frameOffset in 0..<framesToWrite {
                let sourceBase = frameOffset * sourceChannelCount
                let storageBase = storageFrame * channelCount
                for channel in 0..<channelCount {
                    storage[storageBase + channel] = samples[sourceBase + min(channel, sourceChannelCount - 1)]
                }
                storageFrame = advance(storageFrame)
            }
        }

        // Publish the sequence before making these samples visible to playback.
        nextWriteFrameSequence.wrappingAdd(UInt64(framesToWrite), ordering: .releasing)
        writeFrame.store(advance(write, by: framesToWrite), ordering: .releasing)
        return RingBufferWriteResult(
            writtenFrames: framesToWrite,
            droppedInputFrames: requestedFrames - framesToWrite
        )
    }

    func readInterleaved(
        into samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        destinationChannelCount: Int
    ) -> Int {
        let destinationChannelCount = max(destinationChannelCount, 1)
        let requestedFrames = min(frameCount, samples.count / destinationChannelCount)
        guard requestedFrames > 0 else {
            return 0
        }

        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let framesToRead = min(requestedFrames, occupancyFrames(read: read, write: write))

        if destinationChannelCount == channelCount,
           let destination = samples.baseAddress {
            copyFromStorage(
                destination: destination,
                storageFrame: read,
                frameCount: framesToRead
            )
        } else {
            var storageFrame = read
            for frameOffset in 0..<framesToRead {
                let destinationBase = frameOffset * destinationChannelCount
                let storageBase = storageFrame * channelCount
                for channel in 0..<destinationChannelCount {
                    samples[destinationBase + channel] = storage[storageBase + min(channel, channelCount - 1)]
                }
                storageFrame = advance(storageFrame)
            }
        }

        if framesToRead < requestedFrames {
            zeroFill(
                samples,
                startFrame: framesToRead,
                frameCount: requestedFrames - framesToRead,
                channelCount: destinationChannelCount
            )
        }

        readFrame.store(advance(read, by: framesToRead), ordering: .releasing)
        nextReadFrameSequence.wrappingAdd(UInt64(framesToRead), ordering: .releasing)
        return framesToRead
    }

    func nextReadSequence() -> UInt64 {
        nextReadFrameSequence.load(ordering: .acquiring)
    }

    func nextWriteSequence() -> UInt64 {
        nextWriteFrameSequence.load(ordering: .acquiring)
    }

    func occupancyFrames() -> Int {
        let read = readFrame.load(ordering: .acquiring)
        let write = writeFrame.load(ordering: .acquiring)
        return occupancyFrames(read: read, write: write)
    }

    // Consumer-only; returns the number of buffered frames discarded.
    func trimToLatestFrames(_ frames: Int) -> Int {
        let targetFrames = min(max(frames, 0), capacityFrames)
        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let occupancy = occupancyFrames(read: read, write: write)
        guard occupancy > targetFrames else {
            return 0
        }

        let droppedFrames = occupancy - targetFrames
        readFrame.store(advance(read, by: droppedFrames), ordering: .releasing)
        nextReadFrameSequence.wrappingAdd(UInt64(droppedFrames), ordering: .releasing)
        return droppedFrames
    }

    private func occupancyFrames(read: Int, write: Int) -> Int {
        if write >= read {
            return write - read
        }
        return storageFrameCapacity - read + write
    }

    private func advance(_ frame: Int) -> Int {
        let next = frame + 1
        return next == storageFrameCapacity ? 0 : next
    }

    private func advance(_ frame: Int, by distance: Int) -> Int {
        (frame + distance) % storageFrameCapacity
    }

    private func wrapSplit(storageFrame: Int, frameCount: Int) -> (firstSamples: Int, remainingSamples: Int) {
        let firstFrames = min(frameCount, storageFrameCapacity - storageFrame)
        return (firstFrames * channelCount, (frameCount - firstFrames) * channelCount)
    }

    private func copyIntoStorage(source: UnsafePointer<Float>, storageFrame: Int, frameCount: Int) {
        guard frameCount > 0 else { return }
        let split = wrapSplit(storageFrame: storageFrame, frameCount: frameCount)
        let destination = storage.baseAddress!
        destination.advanced(by: storageFrame * channelCount).update(from: source, count: split.firstSamples)
        destination.update(from: source.advanced(by: split.firstSamples), count: split.remainingSamples)
    }

    private func copyFromStorage(destination: UnsafeMutablePointer<Float>, storageFrame: Int, frameCount: Int) {
        guard frameCount > 0 else { return }
        let split = wrapSplit(storageFrame: storageFrame, frameCount: frameCount)
        let source = storage.baseAddress!
        destination.update(from: source.advanced(by: storageFrame * channelCount), count: split.firstSamples)
        destination.advanced(by: split.firstSamples).update(from: source, count: split.remainingSamples)
    }

    private func zeroFill(
        _ samples: UnsafeMutableBufferPointer<Float>,
        startFrame: Int,
        frameCount: Int,
        channelCount: Int
    ) {
        guard frameCount > 0 else {
            return
        }
        samples.baseAddress?
            .advanced(by: startFrame * channelCount)
            .initialize(repeating: 0, count: frameCount * channelCount)
    }
}

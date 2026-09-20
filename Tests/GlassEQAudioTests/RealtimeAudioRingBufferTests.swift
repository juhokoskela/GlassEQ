@testable import GlassEQAudio
import Foundation
import Synchronization
import Testing

@Suite
struct RealtimeAudioRingBufferTests {
    @Test
    func frameSequencesIncludeConsumedAndDiscardedBufferedFrames() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 4)
        let fourFrames: [Float] = [1, 2, 3, 4]
        _ = fourFrames.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 4, sourceChannelCount: 1)
        }
        #expect(ring.nextReadSequence() == 0)
        #expect(ring.nextWriteSequence() == 4)

        let twoFrames: [Float] = [5, 6]
        _ = twoFrames.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 2, sourceChannelCount: 1)
        }
        #expect(ring.nextReadSequence() == 0)
        #expect(ring.nextWriteSequence() == 4)

        var output = [Float](repeating: 0, count: 1)
        output.withUnsafeMutableBufferPointer {
            _ = ring.readInterleaved(into: $0, frameCount: 1, destinationChannelCount: 1)
        }
        #expect(ring.nextReadSequence() == 1)

        #expect(ring.trimToLatestFrames(1) == 2)
        #expect(ring.nextReadSequence() == 3)
        #expect(ring.reset() == 1)
        #expect(ring.nextReadSequence() == 4)
    }

    @Test
    func boundsHostileAllocationDimensions() {
        let ring = RealtimeAudioRingBuffer(
            channelCount: Int.max,
            capacityFrames: Int.max
        )

        #expect(ring.channelCount == 256)
        #expect(ring.capacityFrames == 4_095)
    }

    @Test
    func readsZerosWhenEmpty() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        var frame = [Float](repeating: -1, count: 2)

        let hadData = frame.withUnsafeMutableBufferPointer {
            ring.read(into: $0)
        }

        #expect(!hadData)
        #expect(frame == [0, 0])
    }

    @Test
    func preservesFrameOrder() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let first: [Float] = [1, 2]
        let second: [Float] = [3, 4]
        var output = [Float](repeating: 0, count: 2)

        first.withUnsafeBufferPointer { ring.write($0) }
        second.withUnsafeBufferPointer { ring.write($0) }

        let firstRead = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(firstRead)
        #expect(output == [1, 2])

        let secondRead = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(secondRead)
        #expect(output == [3, 4])
    }

    @Test
    func dropsIncomingFrameWhenFull() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 2)
        let one: [Float] = [1]
        let two: [Float] = [2]
        let three: [Float] = [3]
        var output = [Float](repeating: 0, count: 1)

        one.withUnsafeBufferPointer { ring.write($0) }
        two.withUnsafeBufferPointer { ring.write($0) }
        three.withUnsafeBufferPointer { ring.write($0) }

        _ = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(output == [1])
        _ = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(output == [2])
    }

    @Test
    func partialWriteUsesOnlySpaceReleasedByPlayback() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 4)
        let first: [Float] = [1, 2, 3]
        let second: [Float] = [4, 5, 6, 7]
        var discarded = [Float](repeating: 0, count: 1)
        var output = [Float](repeating: 0, count: 4)

        _ = first.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 3, sourceChannelCount: 1)
        }
        _ = discarded.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 1, destinationChannelCount: 1)
        }
        let result = second.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 4, sourceChannelCount: 1)
        }
        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 4, destinationChannelCount: 1)
        }

        #expect(result.writtenFrames == 2)
        #expect(result.droppedInputFrames == 2)
        #expect(readFrames == 4)
        #expect(output == [2, 3, 4, 5])
    }

    @Test
    func blockReadWritePreservesOrderAcrossWrap() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let first: [Float] = [1, 10, 2, 20, 3, 30]
        let second: [Float] = [4, 40, 5, 50, 6, 60]
        var output = [Float](repeating: 0, count: 8)
        var discarded = [Float](repeating: 0, count: 4)

        _ = first.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 3, sourceChannelCount: 2)
        }
        _ = discarded.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 2, destinationChannelCount: 2)
        }
        _ = second.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 3, sourceChannelCount: 2)
        }

        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 4, destinationChannelCount: 2)
        }

        #expect(readFrames == 4)
        #expect(output == [3, 30, 4, 40, 5, 50, 6, 60])
    }

    @Test
    func blockWriteDropsIncomingTailWhenOverCapacity() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 3)
        let input: [Float] = [1, 2, 3, 4, 5]
        var output = [Float](repeating: 0, count: 3)

        let result = input.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 5, sourceChannelCount: 1)
        }
        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 3, destinationChannelCount: 1)
        }

        #expect(readFrames == 3)
        #expect(output == [1, 2, 3])
        #expect(result.writtenFrames == 3)
        #expect(result.droppedInputFrames == 2)
    }

    @Test
    func blockReadZeroFillsPartialUnderrun() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let input: [Float] = [1, 10, 2, 20]
        var output = [Float](repeating: -1, count: 8)

        _ = input.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 2, sourceChannelCount: 2)
        }
        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 4, destinationChannelCount: 2)
        }

        #expect(readFrames == 2)
        #expect(output == [1, 10, 2, 20, 0, 0, 0, 0])
    }

    @Test
    func blockApisDuplicateAndTruncateChannels() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let monoInput: [Float] = [1, 2]
        var stereoOutput = [Float](repeating: 0, count: 4)

        _ = monoInput.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 2, sourceChannelCount: 1)
        }
        let duplicatedFrames = stereoOutput.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 2, destinationChannelCount: 2)
        }

        let truncatingRing = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let stereoInput: [Float] = [3, 30, 4, 40]
        var monoOutput = [Float](repeating: 0, count: 2)
        _ = stereoInput.withUnsafeBufferPointer {
            truncatingRing.writeInterleaved($0, frameCount: 2, sourceChannelCount: 2)
        }
        let truncatedFrames = monoOutput.withUnsafeMutableBufferPointer {
            truncatingRing.readInterleaved(into: $0, frameCount: 2, destinationChannelCount: 1)
        }

        #expect(duplicatedFrames == 2)
        #expect(stereoOutput == [1, 1, 2, 2])
        #expect(truncatedFrames == 2)
        #expect(monoOutput == [3, 4])
    }

    @Test
    func fullRingRejectsIncomingBlockWithoutAdvancingEitherSequence() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 4)
        let first: [Float] = [1, 2, 3, 4]
        let second: [Float] = [5, 6]

        _ = first.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 4, sourceChannelCount: 1)
        }
        let result = second.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 2, sourceChannelCount: 1)
        }

        #expect(result.writtenFrames == 0)
        #expect(result.droppedInputFrames == 2)
        #expect(ring.occupancyFrames() == 4)
        #expect(ring.nextReadSequence() == 0)
        #expect(ring.nextWriteSequence() == 4)
    }

    @Test
    func resetDiscardsBufferedFramesWithoutBlocking() {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 4)
        let input: [Float] = [1, 10, 2, 20]
        var output = [Float](repeating: -1, count: 4)

        _ = input.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 2, sourceChannelCount: 2)
        }

        #expect(ring.reset() == 2)
        #expect(ring.occupancyFrames() == 0)

        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 2, destinationChannelCount: 2)
        }
        #expect(readFrames == 0)
        #expect(output == [0, 0, 0, 0])
    }

    @Test
    func trimToLatestFramesDropsOldBacklog() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 5)
        let input: [Float] = [1, 2, 3, 4, 5]
        var output = [Float](repeating: 0, count: 2)

        _ = input.withUnsafeBufferPointer {
            ring.writeInterleaved($0, frameCount: 5, sourceChannelCount: 1)
        }

        #expect(ring.trimToLatestFrames(2) == 3)
        #expect(ring.occupancyFrames() == 2)

        let readFrames = output.withUnsafeMutableBufferPointer {
            ring.readInterleaved(into: $0, frameCount: 2, destinationChannelCount: 1)
        }
        #expect(readFrames == 2)
        #expect(output == [4, 5])
    }

    @Test(arguments: [false, true])
    func concurrentIrregularBlocksPreserveAcceptedFrames(discardBacklog: Bool) throws {
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 64)
        let totalFrames = 200_000
        let producerDone = Atomic<Bool>(false)
        let cancelled = Atomic<Bool>(false)
        defer { cancelled.store(true, ordering: .relaxed) }
        let accepted = Mutex((samples: [Float](), droppedFrames: 0))
        let consumed = Mutex((samples: [Float](), discardedFrames: 0))
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var samples = [Float](repeating: 0, count: 129 * 2)
            var acceptedSamples: [Float] = []
            var droppedFrames = 0
            var nextFrame = 1
            var blockIndex = 0
            while nextFrame <= totalFrames && !cancelled.load(ordering: .relaxed) {
                let frames = min([1, 16, 63, 129][blockIndex % 4], totalFrames - nextFrame + 1)
                for frame in 0..<frames {
                    samples[frame * 2] = Float(nextFrame + frame)
                    samples[frame * 2 + 1] = -Float(nextFrame + frame)
                }
                let result = samples.withUnsafeBufferPointer {
                    ring.writeInterleaved($0, frameCount: frames, sourceChannelCount: 2)
                }
                acceptedSamples.append(contentsOf: samples.prefix(result.writtenFrames * 2))
                droppedFrames += result.droppedInputFrames
                nextFrame += frames
                blockIndex += 1
            }
            accepted.withLock { $0 = (acceptedSamples, droppedFrames) }
            producerDone.store(true, ordering: .releasing)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var samples = [Float](repeating: 0, count: 32 * 2)
            var consumedSamples: [Float] = []
            var discardedFrames = 0
            var blockIndex = 0
            while !cancelled.load(ordering: .relaxed) {
                if producerDone.load(ordering: .acquiring) && ring.occupancyFrames() == 0 {
                    break
                }
                if discardBacklog {
                    if blockIndex.isMultiple(of: 53) {
                        discardedFrames += ring.reset()
                    } else if blockIndex.isMultiple(of: 17) {
                        discardedFrames += ring.trimToLatestFrames(16)
                    }
                }
                let frames = [7, 32, 3][blockIndex % 3]
                let count = samples.withUnsafeMutableBufferPointer {
                    ring.readInterleaved(into: $0, frameCount: frames, destinationChannelCount: 2)
                }
                consumedSamples.append(contentsOf: samples.prefix(count * 2))
                blockIndex += 1
            }
            consumed.withLock { $0 = (consumedSamples, discardedFrames) }
            group.leave()
        }

        try #require(group.wait(timeout: .now() + 30) == .success)
        let written = accepted.withLock { $0 }
        let read = consumed.withLock { $0 }
        #expect(written.samples.count > 0)
        #expect(written.samples.count / 2 + written.droppedFrames == totalFrames)
        #expect(read.samples.count / 2 + read.discardedFrames == written.samples.count / 2)
        #expect(ring.nextReadSequence() == UInt64(written.samples.count / 2))
        #expect(ring.nextWriteSequence() == ring.nextReadSequence())
        if discardBacklog {
            let acceptedFrames = Set(stride(from: 0, to: written.samples.count, by: 2).map { written.samples[$0] })
            var previous: Float = 0
            for index in stride(from: 0, to: read.samples.count, by: 2) {
                let frame = read.samples[index]
                #expect(acceptedFrames.contains(frame))
                #expect(frame > previous)
                #expect(read.samples[index + 1] == -frame)
                previous = frame
            }
        } else {
            #expect(read.samples == written.samples)
        }
    }

    @Test
    func sustainedOverflowPreservesFrameIntegrity() {
        // Overflow may drop incoming frames, but every accepted stereo frame must remain intact.
        let ring = RealtimeAudioRingBuffer(channelCount: 2, capacityFrames: 32)
        let producerBlockFrames = 16
        let consumerBlockFrames = 8
        let totalFrames = 200_000
        let producerDone = Atomic<Bool>(false)
        let sawTornFrame = Atomic<Bool>(false)
        let sawRewoundFrame = Atomic<Bool>(false)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var block = [Float](repeating: 0, count: producerBlockFrames * 2)
            var nextValue = 1
            while nextValue <= totalFrames {
                for frame in 0..<producerBlockFrames {
                    // Both channels carry the frame's own value, so a frame stitched together out
                    // of two different writes is detectable on the consumer side.
                    block[frame * 2] = Float(nextValue + frame)
                    block[frame * 2 + 1] = Float(nextValue + frame)
                }
                _ = block.withUnsafeBufferPointer {
                    ring.writeInterleaved($0, frameCount: producerBlockFrames, sourceChannelCount: 2)
                }
                nextValue += producerBlockFrames
            }
            producerDone.store(true, ordering: .releasing)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var block = [Float](repeating: 0, count: consumerBlockFrames * 2)
            var lastValue: Float = 0
            while !producerDone.load(ordering: .acquiring) || ring.occupancyFrames() > 0 {
                let readFrames = block.withUnsafeMutableBufferPointer {
                    ring.readInterleaved(
                        into: $0,
                        frameCount: consumerBlockFrames,
                        destinationChannelCount: 2
                    )
                }
                for frame in 0..<readFrames {
                    let left = block[frame * 2]
                    if left != block[frame * 2 + 1] {
                        sawTornFrame.store(true, ordering: .releasing)
                    }
                    // Dropped incoming frames create gaps, but accepted values must never repeat or rewind.
                    if left <= lastValue {
                        sawRewoundFrame.store(true, ordering: .releasing)
                    }
                    lastValue = left
                }
            }
            group.leave()
        }

        #expect(group.wait(timeout: .now() + 30) == .success)
        let tornFrame = sawTornFrame.load(ordering: .acquiring)
        let rewoundFrame = sawRewoundFrame.load(ordering: .acquiring)
        #expect(!tornFrame)
        #expect(!rewoundFrame)
    }

    @Test
    func concurrentProducerConsumerKeepsReadFramesMonotonic() {
        let ring = RealtimeAudioRingBuffer(channelCount: 1, capacityFrames: 64)
        let producerDone = Atomic<Bool>(false)
        let sawOutOfOrderFrame = Atomic<Bool>(false)
        let consumedFrameCount = Atomic<Int>(0)
        let totalFrames = 20_000
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var frame = [Float](repeating: 0, count: 1)
            for value in 1...totalFrames {
                frame[0] = Float(value)
                frame.withUnsafeBufferPointer {
                    ring.write($0)
                }
                if value.isMultiple(of: 17) {
                    Thread.sleep(forTimeInterval: 0.000_001)
                }
            }
            producerDone.store(true, ordering: .releasing)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var lastFrame = 0
            var frame = [Float](repeating: 0, count: 1)
            while !producerDone.load(ordering: .acquiring) || ring.occupancyFrames() > 0 {
                let hadData = frame.withUnsafeMutableBufferPointer {
                    ring.read(into: $0)
                }
                guard hadData else {
                    Thread.sleep(forTimeInterval: 0.000_001)
                    continue
                }

                let currentFrame = Int(frame[0])
                if currentFrame <= lastFrame {
                    sawOutOfOrderFrame.store(true, ordering: .releasing)
                    break
                }
                lastFrame = currentFrame
                _ = consumedFrameCount.wrappingAdd(1, ordering: .relaxed)
            }
            group.leave()
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        let outOfOrder = sawOutOfOrderFrame.load(ordering: .acquiring)
        let consumed = consumedFrameCount.load(ordering: .acquiring)
        #expect(!outOfOrder)
        #expect(consumed > 0)
    }
}

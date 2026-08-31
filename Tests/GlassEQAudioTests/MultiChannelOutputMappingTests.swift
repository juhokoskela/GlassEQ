import CoreAudio
import Foundation
@testable import GlassEQAudio
import GlassEQCore
import Testing

@Suite
struct MultiChannelOutputMappingTests {
    @Test
    func playbackStereoPairNormalizesPreferredChannels() {
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: nil, outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (1, 2), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 4), outputChannelCount: 6) == (2, 3))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (0, 0), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (7, 8), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 3), outputChannelCount: 6) == (0, 1))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (2, 1), outputChannelCount: 2) == (1, 0))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: (3, 4), outputChannelCount: 1) == (0, 0))
        #expect(SystemTapAudioEngine.playbackStereoPair(preferredChannels: nil, outputChannelCount: 1) == (0, 0))
    }

    @Test
    func deviceTapUsesStreamContainingBothPlaybackChannels() {
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [2],
            playbackChannels: (0, 1)
        ) == 0)
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [2, 2, 2],
            playbackChannels: (2, 3)
        ) == 1)
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [2, 2, 1],
            playbackChannels: (4, 4)
        ) == 2)
    }

    @Test
    func deviceTapRejectsPlaybackChannelsThatCannotShareAStream() {
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [2, 2, 2],
            playbackChannels: (1, 2)
        ) == nil)
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [2, 0, 2],
            playbackChannels: (0, 1)
        ) == nil)
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [],
            playbackChannels: (0, 1)
        ) == nil)
        #expect(SystemTapAudioEngine.tapOutputStreamIndex(
            streamChannelCounts: [6],
            playbackChannels: (2, 3)
        ) == nil)
    }

    @Test
    func playbackChannelPairEncodingRoundTripsAndClamps() {
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 0, right: 1)
        ) == (0, 1))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 2, right: 3)
        ) == (2, 3))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 255, right: 255)
        ) == (255, 255))
        #expect(SystemTapAudioEngine.decodedPlaybackChannelPair(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: -5, right: 999)
        ) == (0, 255))
    }

    @Test
    func stereoSourceMapsToFirstPairOfInterleavedSixChannelBuffer() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [6],
            frames: 3,
            destinationFrameOffset: 1,
            frameCount: 2
        )

        #expect(written == [[
            -1, -1, -1, -1, -1, -1,
            1, 2, 0, 0, 0, 0,
            3, 4, 0, 0, 0, 0
        ]])
    }

    @Test
    func stereoSourceMapsToPreferredPairOfInterleavedSixChannelBuffer() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [6],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [[
            0, 0, 1, 2, 0, 0,
            0, 0, 3, 4, 0, 0
        ]])
    }

    @Test
    func stereoSourceMapsIntoMiddleStreamOfMultiStreamLayout() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2, 2],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [
            [0, 0, 0, 0],
            [1, 2, 3, 4],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func stereoSourcePairCanSpanStreamBoundaries() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2, 2],
            frames: 2,
            pair: (1, 2)
        )

        #expect(written == [
            [0, 1, 0, 3],
            [2, 0, 4, 0],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func monoSourceFeedsBothPairChannelsOnly() {
        let written = mappedCopy(
            source: [5, 6],
            sourceChannelCount: 1,
            channelLayout: [6],
            frames: 2,
            pair: (2, 3)
        )

        #expect(written == [[
            0, 0, 5, 5, 0, 0,
            0, 0, 6, 6, 0, 0
        ]])
    }

    @Test
    func pairBeyondDeviceBuffersProducesSilenceWithoutCrashing() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2, 2],
            frames: 2,
            pair: (4, 5)
        )

        #expect(written == [
            [0, 0, 0, 0],
            [0, 0, 0, 0]
        ])
    }

    @Test
    func chunkedMappedWritesTileWithoutOverwritingEachOther() {
        let written = withMappedBuffers(channelLayout: [6], frames: 4) { buffers in
            let firstChunk: [Float] = [1, 2, 3, 4]
            let secondChunk: [Float] = [5, 6, 7, 8]
            firstChunk.withUnsafeBufferPointer { source in
                SystemTapAudioEngine.copyInterleavedSamples(
                    source,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: 0,
                    frameCount: 2,
                    sourceChannelCount: 2,
                    destinationLeftChannel: 0,
                    destinationRightChannel: 1,
                    to: buffers
                )
            }
            secondChunk.withUnsafeBufferPointer { source in
                SystemTapAudioEngine.copyInterleavedSamples(
                    source,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: 2,
                    frameCount: 2,
                    sourceChannelCount: 2,
                    destinationLeftChannel: 0,
                    destinationRightChannel: 1,
                    to: buffers
                )
            }
        }

        #expect(written == [[
            1, 2, 0, 0, 0, 0,
            3, 4, 0, 0, 0, 0,
            5, 6, 0, 0, 0, 0,
            7, 8, 0, 0, 0, 0
        ]])
    }

    @Test
    func reversedPairSwapsChannelsOnStereoDevice() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2],
            frames: 2,
            pair: (1, 0)
        )

        #expect(written == [[2, 1, 4, 3]])
    }

    @Test
    func identityPairKeepsStereoFastPathBehavior() {
        let written = mappedCopy(
            source: [1, 2, 3, 4],
            sourceChannelCount: 2,
            channelLayout: [2],
            frames: 2,
            pair: (0, 1)
        )

        #expect(written == [[1, 2, 3, 4]])
    }

    @Test
    func tapInputOffsetAccountsForDuplexPhysicalOutput() {
        #expect(SystemTapAudioEngine.tapInputChannelOffset(
            physicalInputChannelCount: 0,
            aggregateInputChannelCount: 2,
            tapChannelCount: 2
        ) == 0)
        #expect(SystemTapAudioEngine.tapInputChannelOffset(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 4,
            tapChannelCount: 2
        ) == 2)
        #expect(SystemTapAudioEngine.tapInputChannelOffset(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 2,
            tapChannelCount: 2
        ) == nil)
    }

    @Test
    func tapInputOffsetsAccountForBothProcessTaps() throws {
        let duplexOffsets = try #require(SystemTapAudioEngine.tapInputChannelOffsets(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 6,
            mainTapChannelCount: 2,
            systemSoundTapChannelCount: 2
        ))
        let outputOnlyOffsets = try #require(SystemTapAudioEngine.tapInputChannelOffsets(
            physicalInputChannelCount: 0,
            aggregateInputChannelCount: 4,
            mainTapChannelCount: 2,
            systemSoundTapChannelCount: 2
        ))
        let reorderedOffsets = try #require(SystemTapAudioEngine.tapInputChannelOffsets(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 6,
            mainTapChannelCount: 2,
            systemSoundTapChannelCount: 2,
            mainTapIndex: 1,
            systemSoundTapIndex: 0
        ))

        #expect(duplexOffsets.main == 2)
        #expect(duplexOffsets.systemSounds == 4)
        #expect(outputOnlyOffsets.main == 0)
        #expect(outputOnlyOffsets.systemSounds == 2)
        #expect(reorderedOffsets.main == 4)
        #expect(reorderedOffsets.systemSounds == 2)
        #expect(SystemTapAudioEngine.tapInputChannelOffsets(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 5,
            mainTapChannelCount: 2,
            systemSoundTapChannelCount: 1
        ) == nil)
        #expect(SystemTapAudioEngine.tapInputChannelOffsets(
            physicalInputChannelCount: 2,
            aggregateInputChannelCount: 6,
            mainTapChannelCount: 2,
            systemSoundTapChannelCount: 2,
            mainTapIndex: 0,
            systemSoundTapIndex: 0
        ) == nil)
    }

    @Test
    func inputStreamUsageEnablesOnlyTapStreams() {
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [2, 2],
            tapChannelOffset: 2,
            tapChannelCount: 2
        ) == [0, 1])
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [2],
            tapChannelOffset: 0,
            tapChannelCount: 2
        ) == [1])
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [2, 2, 2],
            tapChannelOffset: 2,
            tapChannelCount: 4
        ) == [0, 1, 1])
    }

    @Test
    func inputStreamUsageRejectsLayoutsThatCannotIsolateTheTap() {
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [4],
            tapChannelOffset: 2,
            tapChannelCount: 2
        ) == nil)
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [2, 2],
            tapChannelOffset: 2,
            tapChannelCount: 1
        ) == nil)
        #expect(SystemTapAudioEngine.inputStreamUsage(
            streamChannelCounts: [2, 0, 2],
            tapChannelOffset: 2,
            tapChannelCount: 2
        ) == nil)
    }

    @Test
    func aggregateInputCopySkipsPhysicalInputChannels() {
        let interleaved = copiedInput(
            input: [
                10, 11, 1, 2,
                12, 13, 3, 4
            ],
            inputChannelLayout: [4],
            frameCount: 2,
            channelCount: 2,
            sourceChannelOffset: 2
        )
        let split = copiedInput(
            input: [
                10, 11, 12, 13,
                1, 2, 3, 4
            ],
            inputChannelLayout: [2, 2],
            frameCount: 2,
            channelCount: 2,
            sourceChannelOffset: 2
        )

        #expect(interleaved == [1, 2, 3, 4])
        #expect(split == [1, 2, 3, 4])
    }

    @Test
    func systemSoundInputIsMixedWithPerChannelPreamp() {
        let result = mixedInput(
            input: [
                10, 11, 12, 13,
                20, 21, 22, 23,
                0.4, -0.4, 0.2, -0.2
            ],
            inputChannelLayout: [2, 2, 2],
            samples: [0.1, -0.2, 0.3, -0.4],
            frameCount: 2,
            channelCount: 2,
            sourceChannelOffset: 4,
            preampGains: (left: 0.5, right: 0.25)
        )

        #expect(abs(result.samples[0] - 0.3) < 0.000_001)
        #expect(abs(result.samples[1] + 0.3) < 0.000_001)
        #expect(abs(result.samples[2] - 0.4) < 0.000_001)
        #expect(abs(result.samples[3] + 0.45) < 0.000_001)
        #expect(result.saturated == 0)
    }

    @Test
    func systemSoundMixSmoothlyLimitsOverload() {
        let result = mixedInput(
            input: [1, -1],
            inputChannelLayout: [2],
            samples: [0.5, -0.5],
            frameCount: 1,
            channelCount: 2,
            sourceChannelOffset: 0,
            preampGains: (left: 1, right: 1)
        )

        #expect(result.samples[0] > 0.98 && result.samples[0] <= 1)
        #expect(result.samples[1] < -0.98 && result.samples[1] >= -1)
        #expect(result.saturated == 2)
    }

    @Test
    func systemSoundPreampFollowsWholeBankTransitionRamp() {
        let result = mixedInput(
            input: [
                0.1, 0.1,
                0.1, 0.1,
                0.1, 0.1,
                0.1, 0.1
            ],
            inputChannelLayout: [2],
            samples: [Float](repeating: 0, count: 8),
            frameCount: 4,
            channelCount: 2,
            sourceChannelOffset: 0,
            preampGains: (left: 1, right: 1),
            incomingPreampGains: (left: 2, right: 3),
            transition: EQTransitionRenderResult(
                blendStartFrame: 0,
                blendFrameCount: 4
            )
        )

        #expect(abs(result.samples[0] - 0.1) < 0.000_001)
        #expect(abs(result.samples[1] - 0.1) < 0.000_001)
        #expect(result.samples[2] > result.samples[0])
        #expect(result.samples[4] > result.samples[2])
        #expect(abs(result.samples[6] - 0.2) < 0.000_001)
        #expect(abs(result.samples[7] - 0.3) < 0.000_001)
        #expect(result.saturated == 0)
    }

    // MARK: - Helpers

    /// Builds an AudioBufferList with one garbage-prefilled buffer per channelLayout entry,
    /// runs the body against it, and returns the resulting buffer contents.
    private func withMappedBuffers(
        channelLayout: [Int],
        frames: Int,
        prefill: Float = -1,
        _ body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) -> [[Float]] {
        let storages = channelLayout.map { channels -> UnsafeMutableBufferPointer<Float> in
            let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: channels * frames)
            storage.initialize(repeating: prefill)
            return storage
        }
        defer {
            for storage in storages {
                storage.deallocate()
            }
        }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channelLayout.count)
        defer {
            free(bufferList.unsafeMutablePointer)
        }
        for (index, channels) in channelLayout.enumerated() {
            bufferList[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(storages[index].baseAddress)
            )
        }

        body(bufferList)

        return storages.map(Array.init)
    }

    private func mappedCopy(
        source: [Float],
        sourceChannelCount: Int,
        channelLayout: [Int],
        frames: Int,
        destinationFrameOffset: Int = 0,
        frameCount: Int? = nil,
        pair: (left: Int, right: Int) = (0, 1)
    ) -> [[Float]] {
        withMappedBuffers(channelLayout: channelLayout, frames: frames) { buffers in
            source.withUnsafeBufferPointer { sourcePointer in
                SystemTapAudioEngine.copyInterleavedSamples(
                    sourcePointer,
                    sourceFrameOffset: 0,
                    destinationFrameOffset: destinationFrameOffset,
                    frameCount: frameCount ?? frames,
                    sourceChannelCount: sourceChannelCount,
                    destinationLeftChannel: pair.left,
                    destinationRightChannel: pair.right,
                    to: buffers
                )
            }
        }
    }

    private func copiedInput(
        input: [Float],
        inputChannelLayout: [Int],
        frameCount: Int,
        channelCount: Int,
        sourceChannelOffset: Int
    ) -> [Float] {
        var inputOffset = 0
        var samples = Array(repeating: Float.zero, count: frameCount * channelCount)
        _ = withMappedBuffers(channelLayout: inputChannelLayout, frames: frameCount) { buffers in
            for bufferIndex in buffers.indices {
                let sampleCount = inputChannelLayout[bufferIndex] * frameCount
                input.withUnsafeBufferPointer { source in
                    buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self).update(
                        from: source.baseAddress!.advanced(by: inputOffset),
                        count: sampleCount
                    )
                }
                inputOffset += sampleCount
            }
            samples.withUnsafeMutableBufferPointer { destination in
                SystemTapAudioEngine.copyInputSamples(
                    from: buffers,
                    into: destination,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sourceChannelOffset: sourceChannelOffset
                )
            }
        }
        return samples
    }

    private func mixedInput(
        input: [Float],
        inputChannelLayout: [Int],
        samples: [Float],
        frameCount: Int,
        channelCount: Int,
        sourceChannelOffset: Int,
        preampGains: (left: Float, right: Float),
        incomingPreampGains: (left: Float, right: Float)? = nil,
        transition: EQTransitionRenderResult = EQTransitionRenderResult()
    ) -> (samples: [Float], saturated: UInt64) {
        var inputOffset = 0
        var samples = samples
        var saturated: UInt64 = 0
        _ = withMappedBuffers(channelLayout: inputChannelLayout, frames: frameCount) { buffers in
            for bufferIndex in buffers.indices {
                let sampleCount = inputChannelLayout[bufferIndex] * frameCount
                input.withUnsafeBufferPointer { source in
                    buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self).update(
                        from: source.baseAddress!.advanced(by: inputOffset),
                        count: sampleCount
                    )
                }
                inputOffset += sampleCount
            }
            samples.withUnsafeMutableBufferPointer { destination in
                saturated = SystemTapAudioEngine.mixInputSamples(
                    from: buffers,
                    into: destination,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sourceChannelOffset: sourceChannelOffset,
                    preampGains: preampGains,
                    incomingPreampGains: incomingPreampGains,
                    transition: transition
                )
            }
        }
        return (samples, saturated)
    }
}

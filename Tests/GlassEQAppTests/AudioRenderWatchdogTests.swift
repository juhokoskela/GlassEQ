import Testing
@testable import GlassEQApp

@Suite
struct AudioRenderWatchdogTests {
    private let route = AudioRenderWatchdogRoute(
        outputDeviceUID: "output-a",
        nominalSampleRate: 48_000
    )

    @Test
    func advancingRenderHeartbeatPreventsRecovery() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let start = ContinuousClock.now

        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 100,
            at: start
        ) == nil)
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 200,
            at: start.advanced(by: .seconds(2))
        ) == nil)
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 200,
            at: start.advanced(by: .seconds(4))
        ) == nil)
    }

    @Test
    func firstStallRestartsAndRepeatedStallStops() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let start = ContinuousClock.now

        _ = watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 100,
            at: start
        )
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 100,
            at: start.advanced(by: .seconds(3))
        ) == .restart)
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 100,
            at: start.advanced(by: .seconds(5))
        ) == nil)

        _ = watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(6))
        )
        #expect(watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(9))
        ) == .stop)
    }

    @Test
    func generationChangeAndPauseResetHeartbeatWithoutForgettingRecovery() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let start = ContinuousClock.now

        _ = watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 10,
            at: start
        )
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 10,
            at: start.advanced(by: .seconds(3))
        ) == .restart)
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: false,
            playedFrames: 10,
            at: start.advanced(by: .seconds(4))
        ) == nil)
        #expect(watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(5))
        ) == nil)
        #expect(watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(8))
        ) == .stop)
    }

    @Test
    func recoveryHistoryDoesNotLeakAcrossRoutes() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let nextRoute = AudioRenderWatchdogRoute(
            outputDeviceUID: "output-b",
            nominalSampleRate: 48_000
        )
        let start = ContinuousClock.now

        _ = watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start
        )
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(3))
        ) == .restart)
        _ = watchdog.observe(
            generation: 2,
            route: nextRoute,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(4))
        )

        #expect(watchdog.observe(
            generation: 2,
            route: nextRoute,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(7))
        ) == .restart)
    }

    @Test
    func recoveryHistoryDoesNotLeakAcrossNativeStreams() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let firstStream = AudioRenderWatchdogRoute(
            outputDeviceUID: "output-a",
            nativeOutputStreamIndex: 0,
            nominalSampleRate: 48_000
        )
        let secondStream = AudioRenderWatchdogRoute(
            outputDeviceUID: "output-a",
            nativeOutputStreamIndex: 1,
            nominalSampleRate: 48_000
        )
        let start = ContinuousClock.now

        _ = watchdog.observe(
            generation: 1,
            route: firstStream,
            isRunning: true,
            playedFrames: 0,
            at: start
        )
        #expect(watchdog.observe(
            generation: 1,
            route: firstStream,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(3))
        ) == .restart)
        _ = watchdog.observe(
            generation: 2,
            route: secondStream,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(4))
        )

        #expect(watchdog.observe(
            generation: 2,
            route: secondStream,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(7))
        ) == .restart)
    }

    @Test
    func explicitResetForgetsAutomaticRecoveryHistory() {
        var watchdog = AudioRenderWatchdog(
            stallThreshold: .seconds(3),
            repeatedFailureWindow: .seconds(60)
        )
        let start = ContinuousClock.now

        _ = watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start
        )
        #expect(watchdog.observe(
            generation: 1,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(3))
        ) == .restart)

        watchdog.reset()
        _ = watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(4))
        )
        #expect(watchdog.observe(
            generation: 2,
            route: route,
            isRunning: true,
            playedFrames: 0,
            at: start.advanced(by: .seconds(7))
        ) == .restart)
    }
}

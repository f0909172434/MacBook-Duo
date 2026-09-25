import Foundation
@main struct PolicyTests {
    static func main() async {
        typealias P = ScreenCapturePermissionPreparation
        precondition(!P.shouldReset(userConfirmed: false, actualBundleID: P.bundleID))
        precondition(!P.shouldReset(userConfirmed: true, actualBundleID: "another.app"))
        precondition(!P.shouldReset(userConfirmed: true, actualBundleID: nil))
        precondition(P.shouldReset(userConfirmed: true, actualBundleID: P.bundleID))
        let result = await P.prepare()
        precondition(result == nil)
        typealias E = LiveEffectPolicy
        precondition(E.remaining(angle: 0, velocity: 0, endpoint: 97, preview: false) == 1)
        precondition(E.remaining(angle: 97, velocity: 0, endpoint: 97, preview: false) == 0)
        precondition(E.remaining(angle: 120, velocity: 0, endpoint: 97, preview: false) == 0)
        precondition(E.remaining(angle: .nan, velocity: 0, endpoint: 97, preview: false) == 0)
        precondition(E.remaining(angle: 20, velocity: 0, endpoint: 0, preview: false) == 0)
        precondition(E.remaining(angle: 120, velocity: 0, endpoint: 97, preview: true) == 0.35)
        precondition(E.remaining(angle: 90, velocity: -100, endpoint: 97, preview: false) > E.remaining(angle: 90, velocity: 0, endpoint: 97, preview: false))
        precondition(E.captureFPS(remaining: 0, velocity: 0) == 2)
        precondition(E.captureFPS(remaining: 0.5, velocity: 0) == 30)
        precondition(E.captureFPS(remaining: 0, velocity: -20) == 30)
        precondition(E.canRenderRetainedWakeFrame(sleepReasons: ["system"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: []))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["display"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["session"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["lock"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["system", "display"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["system", "session"]))
        precondition(!E.canRenderRetainedWakeFrame(sleepReasons: ["system", "lock"]))
        precondition(E.shouldEnterDormantCapture(remaining: 0, velocity: 0, settled: true,
                                                 overlayVisible: false, previewActive: false,
                                                 secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0.1, velocity: 0, settled: true,
                                                  overlayVisible: false, previewActive: false,
                                                  secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0, velocity: 5, settled: true,
                                                  overlayVisible: false, previewActive: false,
                                                  secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0, velocity: 0, settled: false,
                                                  overlayVisible: false, previewActive: false,
                                                  secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0, velocity: 0, settled: true,
                                                  overlayVisible: true, previewActive: false,
                                                  secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0, velocity: 0, settled: true,
                                                  overlayVisible: false, previewActive: true,
                                                  secondsSinceMotion: 1))
        precondition(!E.shouldEnterDormantCapture(remaining: 0, velocity: 0, settled: true,
                                                  overlayVisible: false, previewActive: false,
                                                  secondsSinceMotion: 0.1))
        precondition(E.retryDelay(failures: 1) == 0, "A first interruption must not add two seconds to wake recovery")
        precondition(E.retryDelay(failures: 0) == 0)
        precondition(E.retryDelay(failures: -1) == 0)
        precondition(E.retryDelay(failures: .min) == 0)
        for failures in 2...16 {
            precondition(E.retryDelay(failures: failures) == min(30, Double(failures) * 2),
                         "Repeated capture failures must retain their bounded backoff")
        }
        precondition(E.retryDelay(failures: 100) == 30)
        precondition(E.retryDelay(failures: .max) == 30)
        // Receiving a complete frame resets the controller's failure count;
        // an interruption after that recovery is a first failure again.
        let failureSequence = [1, 2, 3, 1]
        precondition(failureSequence.map { E.retryDelay(failures: $0) } == [0, 4, 6, 0])
        print("PASS: permission safety, angle boundaries, prediction, capture budget, dormant capture, retained-wake security, retry backoff")
    }
}

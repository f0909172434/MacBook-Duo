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
        precondition(E.retryDelay(failures: 100) == 30)
        print("PASS: permission safety, angle boundaries, prediction, capture budget, retry backoff")
    }
}

import Foundation

/// Pure behavior shared by the controller and hardware-independent tests.
enum LiveEffectPolicy {
    static func remaining(angle: Double, velocity: Double, endpoint: Double, preview: Bool) -> Double {
        if preview { return 0.35 }
        guard angle.isFinite, velocity.isFinite, endpoint.isFinite, endpoint > 0 else { return 0 }
        let prediction = max(-4, min(0, velocity * 0.04))
        return min(1, max(0, 1 - max(0, angle + prediction) / endpoint))
    }
    static func captureFPS(remaining: Double, velocity: Double) -> Int32 {
        remaining > 0.008 || abs(velocity) > 2 ? 30 : 2
    }
    static func canRenderRetainedWakeFrame(sleepReasons: Set<String>) -> Bool {
        sleepReasons == ["system"]
    }
    static func shouldEnterDormantCapture(remaining: Double, velocity: Double, settled: Bool,
                                          overlayVisible: Bool, previewActive: Bool,
                                          secondsSinceMotion: TimeInterval) -> Bool {
        remaining == 0 && abs(velocity) <= 1 && settled && !overlayVisible && !previewActive
            && secondsSinceMotion >= 0.35
    }
    static func retryDelay(failures: Int) -> TimeInterval {
        // A healthy capture may be interrupted as the display sleeps. Let the
        // existing readiness checks retry its first failure on the next recovery
        // tick instead of adding a fixed two-second delay after wake. Repeated
        // failures retain the existing backoff; this does not bypass sleep,
        // session, sensor, display, or screen-recording permission checks.
        guard failures > 1 else { return 0 }
        return min(30, Double(failures) * 2)
    }
}

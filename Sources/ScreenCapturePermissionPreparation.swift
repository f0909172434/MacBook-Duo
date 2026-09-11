import Foundation

/// Startup never changes permissions. Repair requires explicit confirmation.
enum ScreenCapturePermissionPreparation {
    static let bundleID = "studio.prototype.HingeGlass.Global"
    static func shouldReset(userConfirmed: Bool, actualBundleID: String?) -> Bool {
        userConfirmed && actualBundleID == bundleID
    }
    static func prepare() async -> String? { nil }
    static func reset(userConfirmed: Bool) async -> Bool {
        guard shouldReset(userConfirmed: userConfirmed, actualBundleID: Bundle.main.bundleIdentifier) else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ScreenCapture", bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

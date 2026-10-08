import CoreGraphics
import Foundation

/// The PSVR as a macOS display.
///
/// In VR mode the processor unit only shows an image for 1920x1080 RGB at 120 (or 90) Hz,
/// and the HDMI link has to be brought up while the headset is still in cinematic mode:
/// a link that (re)starts in VR mode fails until the cable is replugged. So the order is:
///   cinematic mode -> patched EDID -> 1920x1080 @ 120 Hz -> VR mode.
public enum PSVRDisplay {
    public static let vendorNumber: UInt32 = 0x4DD9   // "SIE"

    public enum SetupError: Error, CustomStringConvertible {
        case notConnected
        case modeUnavailable(Double)
        case modeSwitchFailed(CGError)

        public var description: String {
            switch self {
            case .notConnected:
                return """
                PSVR display not found. Check that the Mac's HDMI goes to the processor unit's "PS4" port \
                and that the displays are extended, not mirrored (System Settings > Displays). \
                If it was working a moment ago, unplug and replug the HDMI cable at the Mac.
                """
            case .modeUnavailable(let hz): return "the PSVR display offers no 1920x1080 @ \(Int(hz)) Hz mode"
            case .modeSwitchFailed(let e): return "could not switch the PSVR display mode (CGError \(e.rawValue))"
            }
        }
    }

    public static func displayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayVendorNumber($0) == vendorNumber }
    }

    public static func waitForDisplay(timeout: TimeInterval, where condition: (CGDirectDisplayID) -> Bool = { _ in true }) -> CGDirectDisplayID? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let id = displayID(), condition(id) { return id }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// 1920x1080 at `hz`, unscaled (1 point = 1 pixel).
    public static func mode(_ id: CGDirectDisplayID, hz: Double) -> CGDisplayMode? {
        let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
        return modes.first { $0.pixelWidth == 1920 && $0.pixelHeight == 1080 && $0.width == 1920 && abs($0.refreshRate - hz) < 1 }
    }

    public static func currentRefreshRate(_ id: CGDirectDisplayID) -> Double {
        CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
    }

    /// Makes 1920x1080 @ `hz` RGB available and active. If the EDID has to be patched the HDMI
    /// link restarts, so `beforeRelink` must put the headset in cinematic mode first.
    @discardableResult
    public static func prepare(hz: Double, beforeRelink: () -> Void = {}, log: (String) -> Void) throws -> CGDirectDisplayID {
        guard var id = waitForDisplay(timeout: 3) else { throw SetupError.notConnected }

        if (try? DisplayEDID.status().0) != .patched || mode(id, hz: hz) == nil {
            log("patching the PSVR display's EDID for 90/120 Hz RGB (the headset image blanks briefly)")
            beforeRelink()
            try DisplayEDID.unlock()
            guard let relinked = waitForDisplay(timeout: 15, where: { mode($0, hz: hz) != nil }) else {
                throw SetupError.notConnected
            }
            id = relinked
        }

        if abs(currentRefreshRate(id) - hz) >= 1 {
            try setRefreshRate(hz, on: id)
            log("PSVR display set to 1920x1080 @ \(Int(hz)) Hz")
        }
        return id
    }

    /// Cinematic mode shows an HDMI error at 120 Hz after VR use; it wants 60 Hz.
    /// Call after switching the headset to cinematic mode (or off).
    public static func restoreCinematicRate() {
        guard let id = displayID(), abs(currentRefreshRate(id) - 60) >= 1 else { return }
        try? setRefreshRate(60, on: id)
    }

    private static func setRefreshRate(_ hz: Double, on id: CGDirectDisplayID) throws {
        guard let m = mode(id, hz: hz) else { throw SetupError.modeUnavailable(hz) }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, id, m, nil)
        let r = CGCompleteDisplayConfiguration(config, .forSession)
        guard r == .success else { throw SetupError.modeSwitchFailed(r) }
        _ = waitForDisplay(timeout: 5) { abs(currentRefreshRate($0) - hz) < 1 }
    }
}

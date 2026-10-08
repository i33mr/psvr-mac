import Foundation
import IOKit

// The PSVR processor unit's EDID caps HDMI at 150 MHz / 61 Hz, so macOS only drives it at 60 Hz.
// The headset stays black in VR mode at 60 Hz, so we inject a patched EDID that adds the
// 1920x1080 @ 90/120 Hz timings a PS4 uses, and declares RGB-only input like a PS4 sends.
//
// Apple Silicon ignores EDID override plists. The private IOAVServiceSetVirtualEDIDMode
// call replaces the EDID at runtime instead (until reset, reboot, or replug).

public enum DisplayEDIDError: Error, CustomStringConvertible {
    case apiUnavailable
    case displayNotFound
    case notPSVR
    case unexpectedLayout(String)
    case failed(String, IOReturn)

    public var description: String {
        switch self {
        case .apiUnavailable: return "IOAVService API not available on this macOS version"
        case .displayNotFound: return "No PSVR (SIE HMD) display found. Is the HDMI connected and the display extended?"
        case .notPSVR: return "The external display is not a PSVR"
        case .unexpectedLayout(let what): return "PSVR EDID has an unexpected layout (\(what)); not patching"
        case .failed(let what, let r): return "\(what) failed (\(String(format: "0x%08x", r)))"
        }
    }
}

public enum DisplayEDID {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    private typealias SetFn = @convention(c) (CFTypeRef, UInt32, CFData?) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let copy = dlsym(iokit, "IOAVServiceCopyEDID").map { unsafeBitCast($0, to: CopyFn.self) }
    private static let set = dlsym(iokit, "IOAVServiceSetVirtualEDIDMode").map { unsafeBitCast($0, to: SetFn.self) }

    /// "SIE" (Sony Interactive Entertainment) manufacturer ID as stored in EDID bytes 8-9.
    static let manufacturerID: [UInt8] = [0x4D, 0xD9]

    public enum Status { case factory, patched, other }

    /// The PSVR's AV service and its current EDID.
    private static func psvrService() throws -> (CFTypeRef, [UInt8]) {
        guard let create, let copy else { throw DisplayEDIDError.apiUnavailable }
        var iterator: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let av = create(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }
            var data: Unmanaged<CFData>?
            guard copy(av, &data) == kIOReturnSuccess, let edid = data?.takeRetainedValue() as Data? else { continue }
            let bytes = [UInt8](edid)
            if bytes.count >= 128, Array(bytes[8...9]) == manufacturerID { return (av, bytes) }
        }
        throw DisplayEDIDError.displayNotFound
    }

    public static func status() throws -> (Status, [UInt8]) {
        let (_, edid) = try psvrService()
        if edid == (try? patch(edid)) { return (.patched, edid) }
        if maxPixelClockMHz(edid) == 150 { return (.factory, edid) }
        return (.other, edid)
    }

    /// Injects the patched EDID, starting from the PSVR's own one. The display re-links
    /// (brief blank) and macOS re-reads its modes a moment later.
    public static func unlock() throws {
        guard let set else { throw DisplayEDIDError.apiUnavailable }
        let (current, _) = try psvrService()
        _ = set(current, 0, nil)
        Thread.sleep(forTimeInterval: 1)
        let (av, factory) = try psvrService()
        let patched = try patch(factory)
        let r = set(av, 1, Data(patched) as CFData)
        guard r == kIOReturnSuccess else { throw DisplayEDIDError.failed("EDID injection", r) }
    }

    /// Drops the injected EDID; the display goes back to what the PSVR reports.
    public static func reset() throws {
        guard let set else { throw DisplayEDIDError.apiUnavailable }
        let (av, _) = try psvrService()
        let r = set(av, 0, nil)
        guard r == kIOReturnSuccess else { throw DisplayEDIDError.failed("EDID reset", r) }
    }

    // MARK: - Patch

    /// Idempotent: patching an already patched EDID returns it unchanged.
    static func patch(_ factory: [UInt8]) throws -> [UInt8] {
        guard factory.count == 256, Array(factory[8...9]) == manufacturerID else { throw DisplayEDIDError.notPSVR }
        var e = factory
        let template = Array(e[54..<72])   // DTD0: 1920x1080 @ 60 (size + sync flags reused)
        guard template[0] != 0 || template[1] != 0 else { throw DisplayEDIDError.unexpectedLayout("no preferred timing") }

        // Base block: 4 descriptors at 54, 72, 90, 108. Find the range-limits one (tag 0xFD)
        // and a second detailed timing to replace with 1080p120.
        var rangeLimits: Int?
        var spareTiming: Int?
        for offset in stride(from: 72, through: 108, by: 18) {
            if e[offset] == 0 && e[offset + 1] == 0 {
                if e[offset + 3] == 0xFD { rangeLimits = offset }
            } else if spareTiming == nil {
                spareTiming = offset
            }
        }
        guard let rangeLimits else { throw DisplayEDIDError.unexpectedLayout("no range limits") }
        guard let spareTiming else { throw DisplayEDIDError.unexpectedLayout("no spare timing slot") }

        e.replaceSubrange(spareTiming..<spareTiming + 18, with: timing1080p(hz: 120, template: template))
        e[24] &= ~0x18                                       // colour encodings: RGB 4:4:4 only
        e[rangeLimits + 6] = max(e[rangeLimits + 6], 121)   // max vertical Hz
        e[rangeLimits + 8] = max(e[rangeLimits + 8], 136)   // max horizontal kHz
        e[rangeLimits + 9] = max(e[rangeLimits + 9], 30)    // max pixel clock / 10 MHz
        e[127] = checksum(e[0..<127])

        // CTA-861 extension: raise the HDMI VSDB TMDS limit and add 1080p90.
        guard e[126] >= 1, e[128] == 0x02 else { throw DisplayEDIDError.unexpectedLayout("no CTA extension") }
        // No YCbCr: the panel is fed raw in VR mode and a PS4 sends RGB.
        e[131] &= ~0x30
        let dtdStart = 128 + Int(e[130])
        var i = 132
        var raisedTMDS = false
        while i < dtdStart {
            let tag = e[i] >> 5, length = Int(e[i] & 0x1F)
            if tag == 3, length >= 7, Array(e[(i + 1)...(i + 3)]) == [0x03, 0x0C, 0x00] {
                e[i + 7] = max(e[i + 7], 60)                  // max TMDS clock / 5 MHz = 300 MHz
                raisedTMDS = true
            }
            i += 1 + length
        }
        guard raisedTMDS else { throw DisplayEDIDError.unexpectedLayout("no HDMI vendor block") }

        let p90 = timing1080p(hz: 90, template: template)
        var slot = dtdStart
        while slot + 18 <= 255 && (e[slot] != 0 || e[slot + 1] != 0) {
            if Array(e[slot..<slot + 18]) == p90 { break }    // already added
            slot += 18
        }
        if slot + 18 <= 255 {
            e.replaceSubrange(slot..<slot + 18, with: p90)
        }
        e[255] = checksum(e[128..<255])
        return e
    }

    /// CTA-861 1080p timing (2200 x 1125 total) at `hz`, which is VIC 63 for 120 Hz.
    static func timing1080p(hz: Int, template: [UInt8]) -> [UInt8] {
        let clock = 2200 * 1125 * hz / 10_000   // in 10 kHz units
        var d = template
        d[0] = UInt8(clock & 0xFF)
        d[1] = UInt8(clock >> 8)
        // Active/blanking/sync bytes 2-11 are identical to 1080p60 (CTA timings share them).
        return d
    }

    static func maxPixelClockMHz(_ edid: [UInt8]) -> Int? {
        for offset in stride(from: 54, through: 108, by: 18) where edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFD {
            return Int(edid[offset + 9]) * 10
        }
        return nil
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        UInt8((256 - bytes.reduce(0) { ($0 + Int($1)) % 256 }) % 256)
    }
}

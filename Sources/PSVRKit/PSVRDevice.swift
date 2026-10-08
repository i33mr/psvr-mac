import Foundation
import IOKit
import IOKit.hid

// PSVR (CUH-ZVR1 / CUH-ZVR2) USB protocol over macOS IOKit HID.
//
// The processor unit exposes several USB interfaces. Two of them are HID and
// matter here:
//   interface 4 - sensor: 64-byte input reports with IMU samples (~1 kHz)
//   interface 5 - control: output reports for commands, 0xF0 status reports
//
// Protocol references: OpenHMD (src/drv_psvr), Monado (drivers/psvr),
// PSVRFramework (gusmanb). All three agree on the commands and IMU layout.

public enum PSVRError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)
    case controlInterfaceMissing
    case writeFailed(command: String, IOReturn)

    public var description: String {
        switch self {
        case .managerOpenFailed(let r):
            return "Could not open IOHIDManager (\(String(format: "0x%08x", r)))"
        case .controlInterfaceMissing:
            return "PSVR control interface not found. Is the processor unit's micro-USB connected to the Mac and the unit powered?"
        case .writeFailed(let command, let r):
            return "Failed to send '\(command)' to the PSVR (\(String(format: "0x%08x", r)))"
        }
    }
}

public enum PSVRCommand {
    case headsetPower(Bool)
    case vrMode(Bool)
    case processorUnitOff
    case requestDeviceInfo
    /// Brightness of the 9 tracking lights (front A–G, back H–I), 0 = off, 100 = full.
    case lights(UInt8)

    public var name: String {
        switch self {
        case .headsetPower(let on): return on ? "headset on" : "headset off"
        case .vrMode(let on): return on ? "VR mode" : "cinematic mode"
        case .processorUnitOff: return "processor unit off"
        case .requestDeviceInfo: return "device info"
        case .lights(let level): return level == 0 ? "lights off" : "lights \(level)%"
        }
    }

    // Report layout: [report id, status, 0xAA, payload length, payload...]
    public var bytes: [UInt8] {
        switch self {
        case .headsetPower(let on): return [0x17, 0x00, 0xAA, 0x04, on ? 1 : 0, 0, 0, 0]
        case .vrMode(let on): return [0x23, 0x00, 0xAA, 0x04, on ? 1 : 0, 0, 0, 0]
        case .processorUnitOff: return [0x13, 0x00, 0xAA, 0x04, 1, 0, 0, 0]
        case .requestDeviceInfo: return [0x81, 0x00, 0xAA, 0x08, 0x80, 0, 0, 0, 0, 0, 0, 0]
        case .lights(let level):
            // Mask 0x01FF selects all 9 lights, then one brightness per light, then padding.
            let v = min(level, 100)
            return [0x15, 0x00, 0xAA, 0x10, 0xFF, 0x01] + [UInt8](repeating: v, count: 9) + [0, 0, 0, 0, 0]
        }
    }
}

public struct PSVRStatus: Equatable {
    public var powered: Bool
    public var worn: Bool
    public var cinematic: Bool
    public var headphonesConnected: Bool
    public var micMuted: Bool
    public var vrMode: Bool
    public var volume: Int

    // 0xF0 report, 20 bytes (Monado psvr_parse_status_packet).
    init?(report: [UInt8]) {
        guard report.count >= 12, report[0] == 0xF0 else { return nil }
        let bits = report[4]
        powered = bits & 0x01 != 0
        worn = bits & 0x02 != 0
        cinematic = bits & 0x04 != 0
        headphonesConnected = bits & 0x10 != 0
        micMuted = bits & 0x20 != 0
        volume = Int(report[5])
        vrMode = report[11] == 1
    }

    public var summary: String {
        "headset \(powered ? "ON" : "off"), mode \(vrMode ? "VR" : "cinematic"), "
            + "\(worn ? "worn" : "not worn"), headphones \(headphonesConnected ? "yes" : "no"), volume \(volume)"
    }
}

public struct IMUSample {
    /// Sensor timestamp in microseconds (24-bit counter, wraps).
    public var tick: UInt32
    /// Angular velocity in rad/s. Axes: x right, y up, z towards the viewer.
    public var gyro: SIMD3<Float>
    /// Specific force in g (reads ~+1 on y when level and still).
    public var accel: SIMD3<Float>
}

public struct SensorPacket {
    public static let buttonVolumeUp: UInt8 = 0x02
    public static let buttonVolumeDown: UInt8 = 0x04
    public static let buttonMicMute: UInt8 = 0x08

    public var buttons: UInt8
    public var samples: (IMUSample, IMUSample)
    /// The face sensor between the lenses sees someone wearing the headset. Clean on/off signal
    /// (measured: flips once, ~0.2 s after putting it on or taking it off). Raising the visor onto the
    /// forehead still counts as worn.
    public var worn: Bool
    /// How close the face sensor sees something: 0 (nothing) to 3 (worn).
    public var proximity: UInt8

    init?(report: UnsafePointer<UInt8>, length: Int) {
        guard length == 64 else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(report[o]) | UInt16(report[o + 1]) << 8 }
        func i16(_ o: Int) -> Float { Float(Int16(bitPattern: u16(o))) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(report[o]) | UInt32(report[o + 1]) << 8 | UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24
        }
        // Raw order is (y, x, z) for both gyro and accel, z is flipped.
        // Scales: BMI055 gyro 0.00105 rad/s per LSB, accel 16384 LSB per g.
        func sample(at o: Int) -> IMUSample {
            IMUSample(
                tick: u32(o),
                gyro: SIMD3(i16(o + 6), i16(o + 4), -i16(o + 8)) * 0.00105,
                accel: SIMD3(i16(o + 12), i16(o + 10), -i16(o + 14)) / 16384
            )
        }
        buttons = report[0]
        samples = (sample(at: 16), sample(at: 32))
        worn = report[8] & 0x01 != 0
        proximity = report[56]
    }
}

public struct PSVRInterfaceInfo {
    public var interfaceNumber: Int?
    public var usagePage: Int
    public var usage: Int
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int
}

public final class PSVR {
    public static let vendorID = 0x054C
    public static let productID = 0x09AF
    static let sensorInterface = 4
    static let controlInterface = 5

    public var onSensor: ((SensorPacket) -> Void)?
    public var onStatus: ((PSVRStatus) -> Void)?
    public var onControlReport: (([UInt8]) -> Void)?
    public var onConnectionChange: ((_ connected: Bool) -> Void)?

    public private(set) var lastStatus: PSVRStatus?

    private let manager: IOHIDManager
    private var sensorDevice: IOHIDDevice?
    private var controlDevice: IOHIDDevice?
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: PSVR.vendorID,
            kIOHIDProductIDKey: PSVR.productID,
        ] as CFDictionary)
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffers.forEach { $0.deallocate() }
    }

    public var isConnected: Bool { controlDevice != nil }
    public var hasSensor: Bool { sensorDevice != nil }

    /// Starts listening. Device arrival is delivered on `runLoop`.
    public func open(on runLoop: CFRunLoop = CFRunLoopGetMain()) throws {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<PSVR>.fromOpaque(ctx!).takeUnretainedValue().deviceMatched(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<PSVR>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw PSVRError.managerOpenFailed(r) }
    }

    /// Runs the given run loop until the control interface shows up or `timeout` passes.
    @discardableResult
    public func waitForConnection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return isConnected
    }

    public func send(_ command: PSVRCommand) throws {
        guard let device = controlDevice else { throw PSVRError.controlInterfaceMissing }
        let bytes = command.bytes
        // Exact-length report first (what OpenHMD/Monado send via hidapi);
        // fall back to padding to the descriptor's max output size.
        var r = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess {
            let maxSize = intProperty(device, kIOHIDMaxOutputReportSizeKey) ?? 64
            if maxSize > bytes.count {
                let padded = bytes + [UInt8](repeating: 0, count: maxSize - bytes.count)
                r = padded.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), $0.baseAddress!, $0.count)
                }
            }
        }
        guard r == kIOReturnSuccess else { throw PSVRError.writeFailed(command: command.name, r) }
    }

    /// Lists every HID interface the PSVR exposes (for diagnostics).
    public func interfaces() -> [PSVRInterfaceInfo] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { d in
            PSVRInterfaceInfo(
                interfaceNumber: interfaceNumber(of: d),
                usagePage: intProperty(d, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: intProperty(d, kIOHIDPrimaryUsageKey) ?? 0,
                maxInputReportSize: intProperty(d, kIOHIDMaxInputReportSizeKey) ?? 0,
                maxOutputReportSize: intProperty(d, kIOHIDMaxOutputReportSizeKey) ?? 0
            )
        }.sorted { ($0.interfaceNumber ?? 99) < ($1.interfaceNumber ?? 99) }
    }

    // MARK: - Device handling

    private func deviceMatched(_ device: IOHIDDevice) {
        switch interfaceNumber(of: device) {
        case PSVR.sensorInterface:
            sensorDevice = device
            registerInputReports(device)
        case PSVR.controlInterface:
            controlDevice = device
            registerInputReports(device)
            onConnectionChange?(true)
        default:
            break
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if device == sensorDevice { sensorDevice = nil }
        if device == controlDevice {
            controlDevice = nil
            onConnectionChange?(false)
        }
    }

    private func registerInputReports(_ device: IOHIDDevice) {
        let size = max(intProperty(device, kIOHIDMaxInputReportSizeKey) ?? 64, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        reportBuffers.append(buffer)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { ctx, _, sender, _, _, report, length in
            let psvr = Unmanaged<PSVR>.fromOpaque(ctx!).takeUnretainedValue()
            psvr.inputReport(from: sender, report: report, length: length)
        }, ctx)
    }

    private func inputReport(from sender: UnsafeMutableRawPointer?, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard let sender else { return }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        if device == sensorDevice {
            if let packet = SensorPacket(report: report, length: length) { onSensor?(packet) }
        } else if device == controlDevice {
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            onControlReport?(bytes)
            if let status = PSVRStatus(report: bytes) {
                lastStatus = status
                onStatus?(status)
            }
        }
    }

    private func interfaceNumber(of device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        let value = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (value as? NSNumber)?.intValue
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

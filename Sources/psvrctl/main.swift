import Foundation
import PSVRKit

let usage = """
usage: psvrctl <command>

  status      show headset power / mode
  on          power the headset on
  vr          power on, set the display to 120 Hz and switch to VR mode
  cinematic   switch back to cinematic mode (virtual screen)
  off         power the headset off
  box-off     power the processor unit off
  lights off|on|<0-100>   the headset's blue tracking lights (front and back)
  sensors     stream head-tracking data (Ctrl-C to stop)
  info        list the HID interfaces macOS sees (diagnostics)

  display status   show whether the 90/120 Hz EDID patch is active
  display unlock   add 1920x1080 @ 90/120 Hz RGB to the PSVR display and select 120 Hz
                   (lasts until reset, reboot or HDMI replug; psvrplayer does this automatically)
  display reset    go back to the PSVR's own EDID (60 Hz only)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments.dropFirst()
guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

/// The HDMI link restarts when the EDID changes, and it only comes back if the headset is
/// in cinematic mode (and has had a moment to get there).
func leaveVRMode() {
    let psvr = PSVR()
    guard (try? psvr.open()) != nil, psvr.waitForConnection(timeout: 2) else { return }
    try? psvr.send(.vrMode(false))
    Thread.sleep(forTimeInterval: 3)
}

if command == "display" {
    let action = args.dropFirst().first ?? "status"
    do {
        switch action {
        case "unlock":
            leaveVRMode()
            try PSVRDisplay.prepare(hz: 120) { print($0) }
        case "reset":
            leaveVRMode()
            try DisplayEDID.reset()
            print("EDID override removed")
        case "status":
            let (status, _) = try DisplayEDID.status()
            switch status {
            case .factory: print("factory EDID (60 Hz max). Run: psvrctl display unlock")
            case .patched: print("patched EDID active (90/120 Hz available)")
            case .other: print("unrecognised EDID (neither factory nor patched)")
            }
        default:
            fail("usage: psvrctl display status|unlock|reset")
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

let psvr = PSVR()
do { try psvr.open() } catch { fail("\(error)") }
guard psvr.waitForConnection(timeout: 3) else {
    fail("""
    PSVR not found on USB.
      - Is the processor unit plugged into power (its AC adapter)?
      - Is its micro-USB port (back) connected to the Mac with a data-capable cable?
      - Check: System Information > USB should list "PS VR".
    """)
}

func runLoop(for seconds: TimeInterval) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

func send(_ cmd: PSVRCommand) {
    do { try psvr.send(cmd) } catch { fail("\(error)") }
}

/// Waits for a status report satisfying `condition`, printing it either way.
// macOS doesn't deliver the headset's status reports (undeclared in its HID descriptor), so this
// usually just times out; it confirms the change on systems that do pass them through.
func awaitStatus(_ description: String, timeout: TimeInterval = 1.5, _ condition: @escaping (PSVRStatus) -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let s = psvr.lastStatus, condition(s) {
            print("ok: \(description) (\(s.summary))")
            return
        }
        runLoop(for: 0.1)
    }
    if let s = psvr.lastStatus {
        print("warning: headset did not confirm \(description) yet (\(s.summary))")
    } else {
        print("sent: \(description)")
    }
}

switch command {
case "status":
    runLoop(for: 1.5)
    print(psvr.lastStatus?.summary ?? "connected, but no status report received in 1.5 s")
    print("sensor interface: \(psvr.hasSensor ? "found" : "missing")")

case "on":
    send(.headsetPower(true))
    awaitStatus("headset on") { $0.powered }

case "vr":
    send(.headsetPower(true))
    runLoop(for: 0.5)
    do {
        try PSVRDisplay.prepare(hz: 120, beforeRelink: {
            send(.vrMode(false))
            runLoop(for: 3)
        }, log: { print($0) })
    } catch {
        fail("\(error)")
    }
    send(.vrMode(true))
    print("VR mode on (display 1920x1080 @ 120 Hz)")

case "cinematic":
    send(.vrMode(false))
    awaitStatus("cinematic mode") { !$0.vrMode }
    PSVRDisplay.restoreCinematicRate()   // cinematic mode shows an HDMI error at 120 Hz

case "off":
    send(.headsetPower(false))
    awaitStatus("headset off") { !$0.powered }

case "lights":
    let arg = args.dropFirst().first ?? ""
    let level: UInt8
    switch arg {
    case "off": level = 0
    case "on": level = 100
    default:
        guard let n = UInt8(arg), n <= 100 else { fail("usage: psvrctl lights off|on|<0-100>") }
        level = n
    }
    send(.lights(level))
    print("sent: \(PSVRCommand.lights(level).name)")

case "box-off":
    send(.processorUnitOff)
    print("sent processor unit off")

case "sensors":
    func buttonNames(_ b: UInt8) -> String {
        var names: [String] = []
        if b & SensorPacket.buttonVolumeUp != 0 { names.append("vol+") }
        if b & SensorPacket.buttonVolumeDown != 0 { names.append("vol-") }
        if b & SensorPacket.buttonMicMute != 0 { names.append("mic") }
        return (names.isEmpty ? "-" : names.joined(separator: ",")).padding(toLength: 12, withPad: " ", startingAt: 0)
            + String(format: "(0x%02x)", b)
    }
    let tracker = OrientationTracker()
    tracker.onStateChange = { _, message in print("tracker: \(message)") }
    var latest: SensorPacket?
    var packetCount = 0
    var rate = 0.0
    var rateStart = Date()
    psvr.onSensor = { packet in
        latest = packet
        packetCount += 1
        tracker.update(packet)
    }
    print("Keep the headset still for ~1 s to calibrate. Ctrl-C to stop.")
    while true {
        runLoop(for: 0.1)
        guard let p = latest else { continue }
        let elapsed = Date().timeIntervalSince(rateStart)
        if elapsed >= 1 {
            rate = Double(packetCount) / elapsed
            packetCount = 0
            rateStart = Date()
        }
        let s = p.samples.0
        let o = tracker.orientation
        // Euler angles for display only (yaw around Y, pitch around X, roll around Z).
        let fwd = o.act(SIMD3<Float>(0, 0, -1))
        let up = o.act(SIMD3<Float>(0, 1, 0))
        let yaw = atan2(-fwd.x, -fwd.z) * 180 / .pi
        let pitch = asin(max(-1, min(1, fwd.y))) * 180 / .pi
        let roll = atan2(-o.act(SIMD3<Float>(1, 0, 0)).y, up.y) * 180 / .pi
        print(String(format: "\rgyro % .2f % .2f % .2f  accel % .2f % .2f % .2f g  |  yaw % 6.1f  pitch % 6.1f  roll % 6.1f  %@ (prox %d)  %4.0f pkt/s  buttons %@  ",
                     s.gyro.x, s.gyro.y, s.gyro.z, s.accel.x, s.accel.y, s.accel.z,
                     yaw, pitch, roll, p.worn ? "worn" : "off ", Int(p.proximity), rate, buttonNames(p.buttons)), terminator: "")
        fflush(stdout)
    }

case "info":
    for i in psvr.interfaces() {
        print(String(format: "interface %@  usagePage 0x%04x usage 0x%02x  in %3d bytes  out %3d bytes",
                     i.interfaceNumber.map(String.init) ?? "?", i.usagePage, i.usage,
                     i.maxInputReportSize, i.maxOutputReportSize))
    }
    psvr.onControlReport = { bytes in
        print("control report: " + bytes.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    send(.requestDeviceInfo)
    runLoop(for: 1.5)

default:
    print(usage)
    exit(1)
}

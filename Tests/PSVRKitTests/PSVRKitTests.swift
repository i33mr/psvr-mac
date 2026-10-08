import XCTest
import simd
@testable import PSVRKit
@testable import PSVRPlayerCore

final class PSVRKitTests: XCTestCase {
    /// Builds a 64-byte sensor report. gyro/accel are in the mapped frame (rad/s, g).
    func report(tick: UInt32, gyro: SIMD3<Float>, accel: SIMD3<Float>, buttons: UInt8 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = buttons
        func put16(_ v: Float, _ o: Int) {
            let raw = UInt16(bitPattern: Int16(max(-32768, min(32767, v.rounded()))))
            b[o] = UInt8(raw & 0xFF); b[o + 1] = UInt8(raw >> 8)
        }
        func sample(_ o: Int, _ t: UInt32) {
            for i in 0..<4 { b[o + i] = UInt8((t >> (8 * UInt32(i))) & 0xFF) }
            let g = gyro / 0.00105, a = accel * 16384
            put16(g.y, o + 4); put16(g.x, o + 6); put16(-g.z, o + 8)
            put16(a.y, o + 10); put16(a.x, o + 12); put16(-a.z, o + 14)
        }
        sample(16, tick)
        sample(32, tick &+ 500)
        b[8] = 0x81    // worn (bit 0), plus the once-a-second tick bit
        b[56] = 3      // proximity level
        return b
    }

    func packet(_ bytes: [UInt8]) -> SensorPacket {
        bytes.withUnsafeBufferPointer { SensorPacket(report: $0.baseAddress!, length: 64)! }
    }

    /// Library labels follow the same rules as the player: metadata, then file-name tokens, then shape.
    func testFormatFromFileName() {
        var info = SphericalInfo()
        info.width = 4096
        info.height = 2048
        XCTAssert(info.resolved(fileName: "Snowy lake_180_sbs")! == (.equirect180, .sbs))
        XCTAssert(info.resolved(fileName: "Ocean waves")! == (.equirect360, .mono))   // 2:1 without tokens
        info.projection = .equirect360   // metadata wins over the name
        XCTAssert(info.resolved(fileName: "Snowy lake_180_sbs")! == (.equirect360, .sbs))
    }

    func testParsing() {
        let p = packet(report(tick: 1234, gyro: SIMD3(0.1, -0.2, 0.3), accel: SIMD3(0, 1, 0), buttons: 0x08))
        XCTAssertEqual(p.buttons, SensorPacket.buttonMicMute)
        XCTAssertEqual(p.samples.0.tick, 1234)
        XCTAssertEqual(p.samples.1.tick, 1734)
        XCTAssertTrue(p.worn)
        XCTAssertEqual(p.proximity, 3)
        XCTAssertEqual(p.samples.0.gyro.x, 0.1, accuracy: 0.002)
        XCTAssertEqual(p.samples.0.gyro.y, -0.2, accuracy: 0.002)
        XCTAssertEqual(p.samples.0.gyro.z, 0.3, accuracy: 0.002)
        XCTAssertEqual(p.samples.1.accel.y, 1, accuracy: 0.001)
    }

    func testStatusParsing() {
        var r = [UInt8](repeating: 0, count: 20)
        r[0] = 0xF0; r[4] = 0x01 | 0x10; r[5] = 30; r[11] = 1
        let s = PSVRStatus(report: r)!
        XCTAssertTrue(s.powered && s.vrMode && s.headphonesConnected && !s.worn)
        XCTAssertEqual(s.volume, 30)
    }

    func testCommands() {
        XCTAssertEqual(PSVRCommand.vrMode(true).bytes, [0x23, 0x00, 0xAA, 0x04, 0x01, 0, 0, 0])
        XCTAssertEqual(PSVRCommand.headsetPower(true).bytes, [0x17, 0x00, 0xAA, 0x04, 0x01, 0, 0, 0])
        let off = PSVRCommand.lights(0).bytes
        XCTAssertEqual(off.count, 4 + 16, "header + 16-byte payload")
        XCTAssertEqual(Array(off[0..<6]), [0x15, 0x00, 0xAA, 0x10, 0xFF, 0x01])
        XCTAssertEqual(Array(off[6..<15]), [UInt8](repeating: 0, count: 9))
        XCTAssertEqual(PSVRCommand.lights(200).bytes[6], 100, "clamped to 100")
    }

    /// Feeds packets at 1 kHz (2 samples each) and returns the tracker.
    func run(_ tracker: OrientationTracker, seconds: Double, startTick: inout UInt32,
             gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        for _ in 0..<Int(seconds * 1000) {
            tracker.update(packet(report(tick: startTick, gyro: gyro, accel: accel)))
            startTick = (startTick &+ 1000) & 0xFFFFFF
        }
    }

    func yaw(_ q: simd_quatf) -> Float {
        let f = q.act(SIMD3<Float>(0, 0, -1))
        return atan2(-f.x, -f.z) * 180 / .pi
    }

    func testCalibrationRemovesBiasAndTracksYaw() {
        let t = OrientationTracker()
        var tick: UInt32 = 0xFFF000   // also exercises the 24-bit wrap
        let bias = SIMD3<Float>(0.01, -0.02, 0.005)
        run(t, seconds: 1.5, startTick: &tick, gyro: bias, accel: SIMD3(0, 1, 0))
        XCTAssertEqual(t.state, .tracking(biasCalibrated: true))
        XCTAssertEqual(yaw(t.orientation), 0, accuracy: 0.5)

        // Turn head left (positive rotation about +y) at 0.5 rad/s for 1 s ≈ 28.6°.
        run(t, seconds: 1, startTick: &tick, gyro: bias + SIMD3(0, 0.5, 0), accel: SIMD3(0, 1, 0))
        XCTAssertEqual(yaw(t.orientation), 28.6, accuracy: 1.5)   // yaw is positive to the left

        // Stay still: no drift from the (removed) bias.
        let before = yaw(t.orientation)
        run(t, seconds: 2, startTick: &tick, gyro: bias, accel: SIMD3(0, 1, 0))
        XCTAssertEqual(yaw(t.orientation), before, accuracy: 0.3)

        t.recenterYaw()
        XCTAssertEqual(yaw(t.orientation), 0, accuracy: 0.1)
    }

    func testGravityCorrectsTilt() {
        let t = OrientationTracker()
        var tick: UInt32 = 0
        run(t, seconds: 1.5, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        // Gyro claims a 20° pitch the accelerometer does not see; gravity should pull it back.
        run(t, seconds: 0.35, startTick: &tick, gyro: SIMD3(1, 0, 0), accel: SIMD3(0, 1, 0))
        let pitched = asin(t.orientation.act(SIMD3<Float>(0, 0, -1)).y) * 180 / .pi
        XCTAssertGreaterThan(abs(pitched), 15)
        run(t, seconds: 8, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        let after = asin(t.orientation.act(SIMD3<Float>(0, 0, -1)).y) * 180 / .pi
        XCTAssertLessThan(abs(after), 1.0)
    }

    /// Feeds 1 kHz packets: `presses` are (start, duration) of mic-mute presses, in seconds.
    func gestures(presses: [(Double, Double)], until end: Double) -> [(Double, ButtonGestures.Gesture)] {
        var g = ButtonGestures()
        var out: [(Double, ButtonGestures.Gesture)] = []
        for ms in 0..<Int(end * 1000) {
            let t = Double(ms) / 1000
            let down = presses.contains { t >= $0.0 && t < $0.0 + $0.1 }
            if let gesture = g.update(buttons: down ? SensorPacket.buttonMicMute : 0, time: t) { out.append((t, gesture)) }
        }
        return out
    }

    func testSinglePressRecenters() {
        let out = gestures(presses: [(1.0, 0.15)], until: 3)
        XCTAssertEqual(out.map(\.1), [.recenter])
    }

    func testDoubleTapIsQuickExit() {
        let out = gestures(presses: [(1.0, 0.1), (1.3, 0.1)], until: 3)
        XCTAssertEqual(out.map(\.1), [.recenter, .quickExit])
        XCTAssertEqual(out[1].0, 1.3, accuracy: 0.002, "fires on the second press, not on release")
    }

    func testSlowPressesOnlyRecenter() {
        let out = gestures(presses: [(1.0, 0.1), (1.8, 0.1), (2.6, 0.1)], until: 4)
        XCTAssertEqual(out.map(\.1), [.recenter, .recenter, .recenter])
    }

    func testHeldButtonIsOnePress() {
        let out = gestures(presses: [(1.0, 0.1)].map { ($0.0, 0.9) }, until: 3)
        XCTAssertEqual(out.map(\.1), [.recenter])
    }

    /// Feeds 1 kHz packets; `presses` are (button, start, duration) in seconds.
    func volumeGestures(_ presses: [(UInt8, Double, Double)], until end: Double) -> [(Double, ButtonGestures.Gesture)] {
        var g = ButtonGestures()
        var out: [(Double, ButtonGestures.Gesture)] = []
        for ms in 0..<Int(end * 1000) {
            let t = Double(ms) / 1000
            let down = presses.first { t >= $0.1 && t < $0.1 + $0.2 }?.0 ?? 0
            if let gesture = g.update(buttons: down, time: t) { out.append((t, gesture)) }
        }
        return out
    }

    func testVolumeTapsSeek() {
        let out = volumeGestures([(SensorPacket.buttonVolumeUp, 1.0, 0.15), (SensorPacket.buttonVolumeDown, 2.0, 0.2)], until: 3)
        XCTAssertEqual(out.map(\.1), [.seekForward, .seekBackward])
        XCTAssertEqual(out[0].0, 1.15, accuracy: 0.002, "a tap fires on release")
    }

    func testVolumeHoldTogglesPlayOnce() {
        let out = volumeGestures([(SensorPacket.buttonVolumeDown, 1.0, 2.0)], until: 4)
        XCTAssertEqual(out.map(\.1), [.togglePlayPause], "no seek on release after a hold")
        XCTAssertEqual(out[0].0, 1.6, accuracy: 0.002, "fires while still held")
    }

    func testSwitchingVolumeButtonsDirectly() {
        // vol+ then vol- with no gap in between (one-button-at-a-time remote).
        let out = volumeGestures([(SensorPacket.buttonVolumeUp, 1.0, 0.2), (SensorPacket.buttonVolumeDown, 1.2, 0.2)], until: 2)
        XCTAssertEqual(out.map(\.1), [.seekForward, .seekBackward])
    }

    func testMicAndVolumeIndependent() {
        var g = ButtonGestures()
        var out: [ButtonGestures.Gesture] = []
        let script: [(Double, UInt8)] = [(0.0, SensorPacket.buttonMicMute), (0.1, 0), (2.0, SensorPacket.buttonVolumeUp), (2.1, 0)]
        for (t, b) in script { if let x = g.update(buttons: b, time: t) { out.append(x) } }
        XCTAssertEqual(out, [.recenter, .seekForward])
    }

    /// YouTube VR180 projection box (`ytmp`), captured from a real 8K VR180 video.
    func testYouTubeVR180Mesh() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "youtube-vr180", withExtension: "ytmp", subdirectory: "Fixtures"))
        let meshes = try SphericalMesh.parse(projectionPayload: Data(contentsOf: url))
        XCTAssertEqual(meshes.count, 1, "one mesh shared by both eyes")
        let mesh = meshes[0]
        XCTAssertEqual(mesh.positions.count, 400)
        XCTAssertEqual(mesh.triangles.count, (798 - 2) * 3, "one triangle strip of 798 indices")
        for p in mesh.positions {
            XCTAssertEqual(simd_length(p), 1, accuracy: 0.001)
            XCTAssertLessThanOrEqual(p.z, 0.001, "front hemisphere only (VR180)")
        }
        // Looking straight ahead hits the middle of the eye image; up is the top edge (v = 0 after the flip).
        let ahead = mesh.positions.indices.min { simd_distance(mesh.positions[$0], SIMD3(0, 0, -1)) < simd_distance(mesh.positions[$1], SIMD3(0, 0, -1)) }!
        XCTAssertEqual(mesh.uvs[ahead].x, 0.5, accuracy: 0.05)
        XCTAssertEqual(mesh.uvs[ahead].y, 0.5, accuracy: 0.05)
        let top = mesh.positions.indices.max { mesh.positions[$0].y < mesh.positions[$1].y }!
        XCTAssertEqual(mesh.uvs[top].y, 0, accuracy: 0.01)
        let right = mesh.positions.indices.max { mesh.positions[$0].x < mesh.positions[$1].x }!
        XCTAssertEqual(mesh.uvs[right].x, 1, accuracy: 0.01)
    }

    /// A bias learned from a slowly moving headset is corrected once it rests.
    func testWrongInitialBiasIsCorrectedWhileStill() {
        let t = OrientationTracker()
        var tick: UInt32 = 0
        run(t, seconds: 1.5, startTick: &tick, gyro: SIMD3(0, 0.05, 0), accel: SIMD3(0, 1, 0))
        run(t, seconds: 10, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        let before = yaw(t.orientation)
        run(t, seconds: 2, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        XCTAssertEqual(yaw(t.orientation), before, accuracy: 0.2)
    }

    /// A steady head turn must not be learned as bias.
    func testSlowTurnIsNotAbsorbed() {
        let t = OrientationTracker()
        var tick: UInt32 = 0
        run(t, seconds: 1.5, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        run(t, seconds: 5, startTick: &tick, gyro: SIMD3(0, 0.1, 0), accel: SIMD3(0, 1, 0))
        XCTAssertEqual(yaw(t.orientation), 0.5 * 180 / .pi, accuracy: 1)
    }

    /// Calibrating while upside down must not flip the view once the headset is turned upright.
    func testCalibratingUpsideDownThenUpright() {
        let t = OrientationTracker()
        var tick: UInt32 = 0
        run(t, seconds: 1.5, startTick: &tick, gyro: .zero, accel: SIMD3(0, -1, 0))
        // Roll 180° about the forward axis over 1 s, then rest upright.
        run(t, seconds: 1, startTick: &tick, gyro: SIMD3(0, 0, .pi), accel: SIMD3(0, 1, 0))
        run(t, seconds: 1, startTick: &tick, gyro: .zero, accel: SIMD3(0, 1, 0))
        XCTAssertEqual(t.orientation.act(SIMD3<Float>(0, 1, 0)).y, 1, accuracy: 0.05)
    }

    func testStartsLevelFromGravity() {
        let t = OrientationTracker()
        var tick: UInt32 = 0
        // Headset resting pitched down 30°: gravity has a +z component in body frame.
        let a = SIMD3<Float>(0, cos(.pi / 6), -sin(.pi / 6))
        run(t, seconds: 1.5, startTick: &tick, gyro: .zero, accel: a)
        let up = t.orientation.act(simd_normalize(a))
        XCTAssertEqual(up.y, 1, accuracy: 0.01)
    }

    /// Factory EDID read from a CUH-ZVR2 processor unit in cinematic mode.
    static let factoryEDIDHex = "00ffffffffffff004dd903b401010101261b0103801009780a3da5a9563db6220c5054200000d1c00101010101010101010101010101023a801871382d40582c4500a05a0000001ed60980a020e02d101060a200a05a00000018000000fc005349452020484d44202a30380a000000fd00173d1a440f000a20202020202001fa020325f04c901f05142004130203111201230907078301000068030c002100001e0fe2006a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a3"

    func testEDIDPatch() throws {
        let hex = Self.factoryEDIDHex
        let factory = stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...hex.index(hex.startIndex, offsetBy: $0 + 1)], radix: 16)!
        }
        XCTAssertEqual(DisplayEDID.maxPixelClockMHz(factory), 150)
        let patched = try DisplayEDID.patch(factory)
        XCTAssertEqual(patched.count, 256)
        XCTAssertEqual(try DisplayEDID.patch(patched), patched, "patch must be idempotent")
        XCTAssertEqual(DisplayEDID.maxPixelClockMHz(patched), 300)
        XCTAssertEqual(patched[0..<128].reduce(0) { ($0 + Int($1)) % 256 }, 0, "base checksum")
        XCTAssertEqual(patched[128..<256].reduce(0) { ($0 + Int($1)) % 256 }, 0, "extension checksum")
        XCTAssertEqual(Array(patched[54..<72]), Array(factory[54..<72]), "1080p60 stays preferred")

        // Collect all detailed timings and their refresh rates.
        func rates(_ e: [UInt8]) -> [Int] {
            var offsets = Array(stride(from: 54, through: 108, by: 18))
            offsets += Array(stride(from: 128 + Int(e[130]), through: 237, by: 18))
            return offsets.compactMap { o in
                let clock = Int(e[o]) | Int(e[o + 1]) << 8
                guard clock != 0 else { return nil }
                let h = Int(e[o + 2]) | Int(e[o + 4] >> 4) << 8, hb = Int(e[o + 3]) | Int(e[o + 4] & 0xF) << 8
                let v = Int(e[o + 5]) | Int(e[o + 7] >> 4) << 8, vb = Int(e[o + 6]) | Int(e[o + 7] & 0xF) << 8
                guard h == 1920, v == 1080 else { return nil }
                return Int((Double(clock) * 10_000 / Double((h + hb) * (v + vb))).rounded())
            }
        }
        XCTAssertEqual(Set(rates(patched)), [60, 90, 120])
        XCTAssertEqual(patched[24] & 0x18, 0, "base block: RGB only")
        XCTAssertEqual(patched[131] & 0x30, 0, "CTA: no YCbCr")
    }
}

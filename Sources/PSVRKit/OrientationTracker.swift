import Foundation
import simd

/// Gyro integration with gravity tilt correction and gyro bias estimation.
/// Thread-safe: feed packets from the HID thread, read from the render thread.
public final class OrientationTracker {
    public enum State: Equatable {
        case calibrating
        case tracking(biasCalibrated: Bool)
    }

    /// Fraction of the tilt error removed per second.
    public var gravityGain: Float = 0.5
    /// Seconds of motion prediction applied by `predictedOrientation`.
    public var predictionSeconds: Float = 0.012

    private let lock = NSLock()
    private var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)   // body -> world
    private var recenter = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var bias = SIMD3<Float>(repeating: 0)
    private var lastGyro = SIMD3<Float>(repeating: 0)
    private var lastTick: UInt32?
    // Stillness detection from raw sensor stability (independent of the current bias estimate).
    private var fastGyro = SIMD3<Float>(repeating: 0)
    private var slowGyro = SIMD3<Float>(repeating: 0)
    private var slowAccel = SIMD3<Float>(0, 1, 0)
    private var stillTime: Float = 0
    private var _state = State.calibrating

    // Calibration: the headset has to be still for `calibrationSamples`.
    private let skipPackets = 50              // the unit replays buffered samples on connect
    private let calibrationSamples = 2000     // ~1 s at 2 kHz
    private let calibrationTimeout = 6.0
    private var packetsSeen = 0
    private var calibStart: Date?
    private var gyroSum = SIMD3<Float>(repeating: 0)
    private var accelSum = SIMD3<Float>(repeating: 0)
    private var calibCount = 0

    public var onStateChange: ((State, String) -> Void)?

    public init() {}

    public var state: State { lock.withLock { _state } }

    public func reset() {
        lock.withLock {
            q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            recenter = q
            bias = .zero
            lastTick = nil
            packetsSeen = 0
            calibStart = nil
            resetCalibrationSums()
            _state = .calibrating
        }
    }

    /// Makes the current heading the forward direction (yaw only).
    public func recenterYaw() {
        lock.withLock {
            let forward = q.act(SIMD3<Float>(0, 0, -1))
            let heading = atan2(-forward.x, -forward.z)
            recenter = simd_quatf(angle: -heading, axis: SIMD3(0, 1, 0))
        }
    }

    public var orientation: simd_quatf { lock.withLock { recenter * q } }

    public var predictedOrientation: simd_quatf { predictedOrientation(ahead: predictionSeconds) }

    /// Orientation extrapolated `seconds` ahead with the current angular velocity.
    public func predictedOrientation(ahead seconds: Float) -> simd_quatf {
        lock.withLock {
            let w = lastGyro
            let angle = simd_length(w) * max(0, min(seconds, 0.05))
            guard angle > 1e-6 else { return recenter * q }
            return recenter * q * simd_quatf(angle: angle, axis: simd_normalize(w))
        }
    }

    public func update(_ packet: SensorPacket) {
        var notify: (State, String)?
        lock.withLock {
            packetsSeen += 1
            guard packetsSeen > skipPackets else { return }
            for s in [packet.samples.0, packet.samples.1] {
                if let n = process(s) { notify = n }
            }
        }
        if let (state, message) = notify { onStateChange?(state, message) }
    }

    // MARK: - Private (called with lock held)

    private func process(_ s: IMUSample) -> (State, String)? {
        var dt: Float = 0.0005
        if let last = lastTick {
            let delta = (s.tick &- last) & 0xFFFFFF
            if delta >= 100 && delta <= 5000 { dt = Float(delta) * 1e-6 }
        }
        lastTick = s.tick

        if _state == .calibrating { return calibrate(s) }

        let accel = s.accel
        let w = s.gyro - bias
        lastGyro = w

        // Integrate body-frame angular velocity.
        let angle = simd_length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatf(angle: angle, axis: w / simd_length(w)))
        }

        let accelNorm = simd_length(accel)

        // Track gyro bias while the headset is held still: the slow average of the raw gyro
        // is then the bias. Rotations faster than 0.08 rad/s are never absorbed.
        fastGyro += (s.gyro - fastGyro) * min(dt / 0.05, 1)
        slowGyro += (s.gyro - slowGyro) * min(dt / 0.5, 1)
        slowAccel += (accel - slowAccel) * min(dt / 0.5, 1)
        let steady = simd_length(fastGyro - slowGyro) < 0.02
            && simd_length(accel - slowAccel) < 0.05
            && abs(accelNorm - 1) < 0.05
            && simd_length(slowGyro - bias) < 0.08
        stillTime = steady ? stillTime + dt : 0
        if stillTime > 0.5 {
            bias += (slowGyro - bias) * min(dt / 2, 1)
        }

        // Pull "up" towards the measured gravity direction.
        if abs(accelNorm - 1) < 0.1 && simd_length(w) < 1.0 {
            let measuredUp = q.act(accel / accelNorm)
            let axis = simd_cross(measuredUp, SIMD3(0, 1, 0))
            let sinAngle = simd_length(axis)
            if sinAngle > 1e-5 {
                let error = atan2(sinAngle, simd_dot(measuredUp, SIMD3(0, 1, 0)))
                let correction = simd_quatf(angle: error * min(gravityGain * dt, 1), axis: axis / sinAngle)
                q = simd_normalize(correction * q)
            }
        }
        return nil
    }

    private func calibrate(_ s: IMUSample) -> (State, String)? {
        let now = Date()
        if calibStart == nil { calibStart = now }

        if calibCount > 50 {
            let n = Float(calibCount)
            if simd_length(s.gyro - gyroSum / n) > 0.06 || simd_length(s.accel - accelSum / n) > 0.05 {
                resetCalibrationSums()
            }
        }
        gyroSum += s.gyro
        accelSum += s.accel
        calibCount += 1

        let timedOut = now.timeIntervalSince(calibStart!) > calibrationTimeout
        guard calibCount >= calibrationSamples || timedOut else { return nil }

        let calibrated = calibCount >= calibrationSamples
        var message: String
        if calibrated {
            bias = gyroSum / Float(calibCount)
            slowGyro = bias
            fastGyro = bias
            message = String(format: "gyro bias calibrated (%.4f, %.4f, %.4f rad/s)", bias.x, bias.y, bias.z)
        } else {
            bias = .zero
            message = "headset kept moving; skipped bias calibration (expect slow drift, it self-corrects while still)"
        }

        // Start from the resting attitude: rotate so measured gravity points up.
        let up = accelSum / Float(max(calibCount, 1))
        if simd_length(up) > 0.5 {
            q = simd_quatf(from: simd_normalize(up), to: SIMD3(0, 1, 0))
        }
        let forward = q.act(SIMD3<Float>(0, 0, -1))
        recenter = simd_quatf(angle: -atan2(-forward.x, -forward.z), axis: SIMD3(0, 1, 0))
        _state = .tracking(biasCalibrated: calibrated)
        return (_state, message)
    }

    private func resetCalibrationSums() {
        gyroSum = .zero
        accelSum = .zero
        calibCount = 0
    }
}

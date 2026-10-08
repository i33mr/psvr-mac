import Foundation

/// Headset inline-remote gestures. The remote reports one button at a time
/// (pressing two together reads as one of them), so gestures are sequences and holds.
public struct ButtonGestures {
    public enum Gesture: Equatable {
        /// Mic-mute pressed once.
        case recenter
        /// Mic-mute pressed twice within `doubleTapWindow`.
        case quickExit
        /// Volume+ tapped (fires on release).
        case seekForward
        /// Volume− tapped (fires on release).
        case seekBackward
        /// Either volume button held for `holdDuration` (fires once, while still held).
        case togglePlayPause
    }

    public var doubleTapWindow: TimeInterval = 0.5
    public var holdDuration: TimeInterval = 0.6

    private var previousButtons: UInt8 = 0
    private var lastMicPress: TimeInterval?
    private var volumePress: (button: UInt8, start: TimeInterval, held: Bool)?

    public init() {}

    /// Feed every sensor packet's button byte with a monotonic timestamp (seconds).
    public mutating func update(buttons: UInt8, time: TimeInterval) -> Gesture? {
        defer { previousButtons = buttons }
        return micGesture(buttons, time) ?? volumeGesture(buttons, time)
    }

    private mutating func micGesture(_ buttons: UInt8, _ time: TimeInterval) -> Gesture? {
        let mic = SensorPacket.buttonMicMute
        guard buttons & mic != 0, previousButtons & mic == 0 else { return nil }
        if let last = lastMicPress, time - last <= doubleTapWindow {
            lastMicPress = nil
            return .quickExit
        }
        lastMicPress = time
        return .recenter
    }

    private mutating func volumeGesture(_ buttons: UInt8, _ time: TimeInterval) -> Gesture? {
        let volume = buttons & (SensorPacket.buttonVolumeUp | SensorPacket.buttonVolumeDown)

        if let press = volumePress, volume != press.button {
            // Released (or switched straight to the other button): a tap unless it became a hold.
            volumePress = volume != 0 ? (volume, time, false) : nil
            guard !press.held else { return nil }
            return press.button == SensorPacket.buttonVolumeUp ? .seekForward : .seekBackward
        }
        if volumePress == nil, volume != 0 {
            volumePress = (volume, time, false)
            return nil
        }
        if let press = volumePress, !press.held, time - press.start >= holdDuration {
            volumePress?.held = true
            return .togglePlayPause
        }
        return nil
    }
}

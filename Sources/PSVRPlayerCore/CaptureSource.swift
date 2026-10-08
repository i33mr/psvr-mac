import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import ScreenCaptureKit

/// Live frames of a Mac window or display, for the virtual screen.
final class CaptureSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    private let filter: SCContentFilter
    private let converter: FrameConverter
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    /// Latest captured buffer, handed from the capture queue to the render thread.
    private let latest = OSAllocatedUnfairLock<CVPixelBuffer?>(uncheckedState: nil)
    private var current: (frame: VideoFrame, keepAlive: [CVMetalTexture])?
    private var lastBuffer: CVPixelBuffer?

    var onStopped: ((Error?) -> Void)?
    private(set) var newFrames = 0
    var wantsMipmaps: Bool { true }

    init(filter: SCContentFilter, device: MTLDevice) {
        self.filter = filter
        converter = FrameConverter(device: device)
    }

    func start() async throws {
        let config = SCStreamConfiguration()
        // Capture at the content's real pixel size (Retina), up to 4K wide.
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        if width > 3840 {
            height *= 3840 / width
            width = 3840
        }
        config.width = max(Int(width), 2)
        config.height = max(Int(height), 2)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func frame(hostTime: CFTimeInterval) -> VideoFrame? {
        if let buffer = latest.withLockUnchecked({ $0 }), buffer !== lastBuffer, let made = converter.makeFrame(buffer) {
            lastBuffer = buffer
            current = made
            newFrames += 1
        }
        return current?.frame
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        latest.withLockUnchecked { $0 = buffer }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStopped?(error) }
    }
}

/// Finding something to capture.
public enum CaptureTarget {
    /// Lets the user pick a window or display with the system's sharing picker (no Screen
    /// Recording permission needed). Calls back on the main thread; nil if cancelled.
    @MainActor
    public static func pick(_ completion: @escaping (SCContentFilter?) -> Void) {
        PickerObserver.shared.present(completion)
    }

    /// The frontmost on-screen window whose app or title contains `name` (needs Screen Recording
    /// permission for the terminal/app running this).
    public static func window(named name: String) async throws -> SCContentFilter? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let needle = name.lowercased()
        let match = content.windows.first { w in
            w.windowLayer == 0 && w.frame.width > 200 &&
            ((w.owningApplication?.applicationName.lowercased().contains(needle) ?? false)
             || (w.title?.lowercased().contains(needle) ?? false))
        }
        return match.map { SCContentFilter(desktopIndependentWindow: $0) }
    }

    /// The Mac's main display.
    public static func mainDisplay() async throws -> SCContentFilter? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
        return SCContentFilter(display: display, excludingWindows: [])
    }
}

@MainActor
private final class PickerObserver: NSObject, SCContentSharingPickerObserver {
    static let shared = PickerObserver()
    private var completion: ((SCContentFilter?) -> Void)?

    func present(_ completion: @escaping (SCContentFilter?) -> Void) {
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay, .singleApplication]
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    private func finish(_ filter: SCContentFilter?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let completion = self.completion
        self.completion = nil
        completion?(filter)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.finish(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}

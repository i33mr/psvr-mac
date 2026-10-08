import AppKit
import Metal
import QuartzCore

/// Keyboard input, from the player window or the launching terminal.
public enum Key {
    case esc, space, left, right, up, down
    case char(Character)

    /// The player key for a key press; nil for ⌘ shortcuts.
    public init?(event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return nil }
        switch event.keyCode {
        case 53: self = .esc
        case 49: self = .space
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            self = .char(c)
        }
    }

    func isChar(_ c: Character) -> Bool {
        if case .char(c) = self { return true }
        return false
    }

    func isArrow(_ arrow: Key) -> Bool {
        switch (self, arrow) {
        case (.left, .left), (.right, .right), (.up, .up), (.down, .down): return true
        default: return false
        }
    }
}

/// The borderless window on the headset display (or a normal window for --window previews).
final class PlayerWindow: NSWindow {
    /// False for the virtual screen: keys and clicks must reach the app being shared.
    var takesInput = true

    override var canBecomeKey: Bool { takesInput }
    override var canBecomeMain: Bool { takesInput }

    /// When set, the window stays exactly here. AppKit otherwise moves borderless windows to the
    /// main screen while an app launches/activates, briefly showing the video on the Mac.
    var pinnedFrame: NSRect?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        pinnedFrame ?? super.constrainFrameRect(frameRect, to: screen)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinnedFrame ?? frameRect, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(pinnedFrame?.origin ?? point)
    }
}

/// The optional preview of the headset view on the Mac. Never takes keyboard focus, so keys keep
/// going to the player (or the app being shared).
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let metalLayer = CAMetalLayer()

    init(on screen: NSScreen, device: MTLDevice, width: Int, height: Int) {
        let size = NSSize(width: 640, height: 360)
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = "PSVR Preview"
        isReleasedWhenClosed = false
        contentAspectRatio = NSSize(width: width, height: height)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false   // filled by a copy, not drawn into
        metalLayer.drawableSize = CGSize(width: width, height: height)
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.backgroundColor = NSColor.black.cgColor
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.layer = metalLayer
        view.wantsLayer = true
        contentView = view
    }
}

/// Hosts the CAMetalLayer the render thread draws into; forwards keys and mouse look.
final class PlayerView: NSView {
    let metalLayer = CAMetalLayer()
    var onKey: ((Key) -> Void)?
    var onMouseLook: ((Float, Float) -> Void)?

    init(frame: NSRect, device: MTLDevice) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true   // lets macOS show it directly instead of compositing
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func keyDown(with event: NSEvent) {
        if let key = Key(event: event) { onKey?(key) } else { super.keyDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseLook?(Float(event.deltaX), Float(event.deltaY))
    }
}

func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// NSScreen for a display ID, letting AppKit catch up after display changes.
func screen(for id: CGDirectDisplayID, timeout: TimeInterval = 5) -> NSScreen? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let s = NSScreen.screens.first(where: { displayID($0) == id }) { return s }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return nil
}

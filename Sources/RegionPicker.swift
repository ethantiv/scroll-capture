import AppKit
import Carbon.HIToolbox

/// Shottr-style area selection before a capture: a dimmed overlay with a crosshair on the screen under the mouse.
/// Dragging picks the part of the scroll area to keep, Space takes the whole scroll area under the cursor, Esc cancels.
@MainActor
final class RegionPicker: NSWindow {
    private var continuation: CheckedContinuation<CGRect?, any Error>?
    /// The overlay activates this agent app to receive Space and Esc; the focus goes back afterwards.
    private let previousApp = NSWorkspace.shared.frontmostApplication

    /// The dragged rectangle in global top-left points (CGWindowList's space), nil for Space. Esc throws `CancellationError`.
    static func pick() async throws -> CGRect? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return nil }
        let picker = RegionPicker(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                picker.continuation = continuation
                if Task.isCancelled { picker.finish(.failure(CancellationError())) } else { picker.show() }
            }
        } onCancel: {
            Task { @MainActor in picker.finish(.failure(CancellationError())) }
        }
    }

    override var canBecomeKey: Bool { true }

    private func show() {
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView()
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    fileprivate func finish(_ result: Result<CGRect?, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        orderOut(nil)
        previousApp?.activate()
        continuation.resume(with: result)
    }

    /// Window rectangle → global top-left points: the y axis flips around the primary screen's top.
    fileprivate func globalRect(_ rect: NSRect) -> CGRect {
        let onScreen = convertToScreen(rect)
        return CGRect(x: onScreen.minX, y: NSScreen.screens[0].frame.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
    }
}

private final class SelectionView: NSView {
    private var start: NSPoint?
    private var selection = NSRect.zero
    private var picker: RegionPicker? { window as? RegionPicker }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        if selection.width >= 20, selection.height >= 20, let picker {
            picker.finish(.success(picker.globalRect(convert(selection, to: nil))))
        } else {
            // A plain click or a slip of the hand: keep picking.
            selection = .zero
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Space: picker?.finish(.success(nil))
        case kVK_Escape: picker?.finish(.failure(CancellationError()))
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if selection.isEmpty {
            let hint = NSAttributedString(string: "Zaznacz obszar · Spacja: całe okno · Esc: anuluj",
                                          attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white])
            let size = hint.size()
            let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 120)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: size).insetBy(dx: -14, dy: -8), xRadius: 10, yRadius: 10).fill()
            hint.draw(at: origin)
        } else {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}

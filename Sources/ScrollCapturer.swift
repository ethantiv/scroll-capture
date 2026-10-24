import AppKit
import OSLog
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noWindow, captureFailed, misaligned, notScrolled

    var errorDescription: String? {
        switch self {
        case .noWindow: "Brak okna pod kursorem."
        case .captureFailed: "Nie udało się zrobić zrzutu okna."
        case .misaligned: "Nie udało się dopasować kolejnych zrzutów (animacja lub zmienna treść?)."
        case .notScrolled: "Okno się nie przewinęło (strona już na dole albo kursor poza obszarem przewijania?)."
        }
    }
}

/// Screenshots the window under the mouse, scrolls it down with synthetic wheel events and stitches the frames.
/// Shottr does the same: `CGEventCreateScrollWheelEvent2` + `CGEventPost`, then compares consecutive captures.
@MainActor
struct ScrollCapturer {
    /// Shottr's default; the final image is copied a few times, so 40 000 px peaked near 2 GB.
    var maxHeight = 20_000
    /// Lets smooth-scrolling apps finish moving and repainting before the next capture.
    var settleDelay: Duration = .milliseconds(350)
    /// Extra captures after a failed match before the capture stops.
    var retries = 3

    func capture() async throws -> CGImage {
        try await Self.waitForModifierRelease()
        guard let point = CGEvent(source: nil)?.location else { throw CaptureError.noWindow }
        let (filter, config, bounds) = try await Self.windowFilter(at: point)
        let scale = CGFloat(filter.pointPixelScale)
        // Only the scrolling view (Safari's page without its toolbar and tabs), in the captured image's pixels.
        // An AX area outside the picked window (a floating panel on top) intersects to null: fall back to the window.
        let hit = Self.scrollArea(at: point)?.intersection(bounds) ?? .null
        let area = hit.isEmpty ? bounds : hit
        // A third of the scroll area per step, Shottr's cap too: two thirds of every frame overlap the previous one.
        let step = Int32(area.height / 3)
        let expected = Int(CGFloat(step) * scale)
        let parking = Self.parkingSpot(outside: bounds)
        var crop = CGRect(x: (area.minX - bounds.minX) * scale, y: (area.minY - bounds.minY) * scale,
                          width: area.width * scale, height: area.height * scale).integral
        Self.log.info("start: window \(bounds.debugDescription, privacy: .public) scroll area \(area.debugDescription, privacy: .public) scale \(scale) step \(step) pt, AX trusted \(AXIsProcessTrusted())")
        // Like Shottr: the cursor sits over the window only while scrolling and is parked elsewhere for every capture,
        // so hover effects (highlighted rows, tooltips, a widened scroller) don't differ between frames.
        Self.moveCursor(to: parking)
        defer { Self.moveCursor(to: point) }
        try await Task.sleep(for: settleDelay)

        let firstImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // The window's rounded bottom corners are transparent: every appended slice would carry a notch at both sides.
        // Trimming the corner radius also drops the overlay scroller at the right edge.
        // Capped: a translucent window (a see-through terminal) has no opaque pixel in the bottom row at all.
        let trim = min(max(Frame(firstImage).cornerRadius, Int(16 * scale)), Int(32 * scale))
        crop = crop.insetBy(dx: CGFloat(trim), dy: 0)
        func cropped(_ image: CGImage) throws -> Frame {
            guard let part = image.cropping(to: crop) else { throw CaptureError.captureFailed }
            return Frame(part)
        }
        let first = try cropped(firstImage)
        var stitcher = Stitcher(first: first)
        var previous = firstImage
        var stillSteps = 0
        while stitcher.height < maxHeight {
            // Cancelling (hotkey, click, key press) ends the capture like Shottr's interrupt: keep what is stitched.
            do {
                try Task.checkCancellation()
                Self.moveCursor(to: point)
                // Shottr also waits between moving the cursor and scrolling; right after the move the events were dropped.
                try await Task.sleep(for: .milliseconds(80))
                try await Self.scroll(by: step, at: point)
                Self.moveCursor(to: parking)
                // Shottr tolerates failed matches too (its `nilShifts`): a video, spinner or lazy-loaded block
                // may still be changing, so look again before giving up.
                var shift: Int?
                var next = previous
                for attempt in 0...retries {
                    try await Task.sleep(for: settleDelay)
                    next = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    shift = stitcher.append(try cropped(next), expectedShift: expected)
                    let match = stitcher.lastMatch
                    Self.log.info("attempt \(attempt): shift \(shift ?? -1) px of expected \(expected), best \(match.best, format: .fixed(precision: 2)), changed \(match.changed, format: .fixed(precision: 2)), height \(stitcher.height)")
                    if shift != nil { break }
                }
                guard let shift else {
                    Self.saveForDebugging(previous: previous, failed: next)
                    // Keep what is already stitched; failing only makes sense before the first step.
                    if stitcher.height > first.height { break }
                    throw CaptureError.misaligned
                }
                previous = next
                // A page that is still loading or repainting can sit still for one step; two in a row is the end.
                stillSteps = shift == 0 ? stillSteps + 1 : 0
                if stillSteps == 2 { break }
            } catch {
                // An interrupt, or a capture failing mid-run (the window closed or left the screen): keep what is stitched.
                Self.log.info("stopped at \(stitcher.height) px: \(error.localizedDescription, privacy: .public)")
                // Nothing stitched yet: a lone window screenshot isn't worth overwriting the clipboard.
                if stitcher.height == first.height { throw error }
                break
            }
        }
        Self.log.info("done: \(stitcher.height) px")
        // Shottr's "wasn't able to scroll": a plain window screenshot with the success sound would hide the problem.
        if stillSteps == 2 && stitcher.height == first.height { throw CaptureError.notScrolled }
        guard let result = stitcher.image().cgImage(colorSpace: firstImage.colorSpace) else { throw CaptureError.captureFailed }
        return result
    }

    private static let log = Logger(subsystem: "com.mirek.scrollcapture", category: "capture")

    /// The last pair that wouldn't line up, overwritten on every failure, for working out why.
    private static func saveForDebugging(previous: CGImage, failed: CGImage) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.mirek.scrollcapture")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, image) in [("previous", previous), ("failed", failed)] {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        }
        log.error("no matching shift; frames saved to \(folder.path, privacy: .public)")
    }

    /// The hotkey's ⌃⌥⌘ would otherwise ride along on the first scroll events and turn them into zoom or other gestures.
    private static func waitForModifierRelease() async throws {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let deadline = ContinuousClock.now + .seconds(2)
        while !CGEventSource.flagsState(.hidSystemState).isDisjoint(with: modifiers), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The nearest scroll area at `point` and up its ancestors, in global top-left points; nil when the app exposes none.
    private static func scrollArea(at point: CGPoint) -> CGRect? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return nil }
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        var element = hit
        while let current = element {
            if value(current, kAXRoleAttribute) as? String == kAXScrollAreaRole,
               let position = value(current, kAXPositionAttribute), let size = value(current, kAXSizeAttribute) {
                var origin = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
                return CGRect(origin: origin, size: extent)
            }
            element = value(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    /// A real mouse-moved event, not `CGWarpMouseCursorPosition`: a warp sends apps no movement, so Safari kept
    /// its hover state and ignored the scroll events that followed.
    private static func moveCursor(to point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Shottr parks the cursor at the main display's right edge, 100 pt down; use the left edge when the window covers that spot.
    private static func parkingSpot(outside window: CGRect) -> CGPoint {
        let display = CGDisplayBounds(CGMainDisplayID())
        let right = CGPoint(x: display.maxX - 2, y: display.minY + 100)
        let left = CGPoint(x: display.minX + 1, y: display.minY + 100)
        return window.contains(right) && !window.contains(left) ? left : right
    }

    /// The topmost normal window under `point` (global, top-left origin) and its bounds. CGWindowList is ordered front to back; SCShareableContent is not.
    private static func windowFilter(at point: CGPoint) async throws -> (SCContentFilter, SCStreamConfiguration, CGRect) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hit = info.first { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? Int32 != ownPID,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.contains(point)
        }
        guard let id = hit?[kCGWindowNumber as String] as? CGWindowID,
              let dict = hit?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { throw CaptureError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return (filter, config, bounds)
    }

    /// A stream of small pixel-unit events, like a smooth-scrolling mouse: apps don't reliably apply one huge synthetic delta.
    /// Pixel deltas are in points, so the expected shift is known. Negative = scroll down; synthetic events skip the "natural scrolling" flip.
    /// A private-state source keeps the keyboard's modifier state out of the events.
    private static func scroll(by points: Int32, at point: CGPoint) async throws {
        let source = CGEventSource(stateID: .privateState)
        var left = points
        while left > 0 {
            let delta = min(20, left)
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.flags = []
            event?.post(tap: .cghidEventTap)
            left -= delta
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}

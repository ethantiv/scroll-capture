import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noWindow, captureFailed, misaligned

    var errorDescription: String? {
        switch self {
        case .noWindow: "Brak okna pod kursorem."
        case .captureFailed: "Nie udało się zrobić zrzutu okna."
        case .misaligned: "Nie udało się dopasować kolejnych zrzutów (animacja lub zmienna treść?)."
        }
    }
}

/// Screenshots the window under the mouse, scrolls it down with synthetic wheel events and stitches the frames.
/// Shottr does the same: `CGEventCreateScrollWheelEvent2` + `CGEventPost`, then compares consecutive captures.
@MainActor
struct ScrollCapturer {
    var maxHeight = 40_000
    /// Lets smooth-scrolling apps finish moving and repainting before the next capture.
    var settleDelay: Duration = .milliseconds(350)

    func capture() async throws -> CGImage {
        guard let point = CGEvent(source: nil)?.location else { throw CaptureError.noWindow }
        let (filter, config) = try await Self.windowFilter(at: point)
        let scale = CGFloat(filter.pointPixelScale)
        // Half a window per step leaves a wide overlap for matching.
        let step = Int32(filter.contentRect.height / 2)

        let firstImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        var stitcher = Stitcher(first: Frame(firstImage), scrollbarGuard: Int(20 * scale))
        while stitcher.height < maxHeight {
            try Task.checkCancellation()
            Self.scroll(by: step, at: point)
            try await Task.sleep(for: settleDelay)
            let next = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let shift = stitcher.append(Frame(next), expectedShift: Int(CGFloat(step) * scale)) else {
                throw CaptureError.misaligned
            }
            if shift == 0 { break }
        }
        guard let result = stitcher.image().cgImage(colorSpace: firstImage.colorSpace) else { throw CaptureError.captureFailed }
        return result
    }

    /// The topmost normal window under `point` (global, top-left origin). CGWindowList is ordered front to back; SCShareableContent is not.
    private static func windowFilter(at point: CGPoint) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hit = info.first { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? Int32 != ownPID,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.contains(point)
        }
        guard let id = hit?[kCGWindowNumber as String] as? CGWindowID else { throw CaptureError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return (filter, config)
    }

    /// Pixel units: the delta is in points, so the expected shift is known. Negative = scroll down; synthetic events skip the "natural scrolling" flip.
    private static func scroll(by points: Int32, at point: CGPoint) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }
}

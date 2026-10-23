import CoreGraphics
import Foundation

/// Raw RGBA pixels, row 0 at the top.
struct Frame: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt32]
}

/// Glues consecutive screenshots of a scrolling view into one tall image.
/// Same idea as Shottr's `ScrollCapturer.findShift` + `combine`: find the vertical shift between
/// two frames, then append only the rows that scrolled into view.
struct Stitcher {
    /// Columns at the right edge of the scrolling area ignored when matching rows: an overlay scroller's thumb moves with every step.
    let scrollbarGuard: Int
    private let first: Frame
    private var last: Frame
    /// Rows that scroll (everything between a static header and footer); empty until the first movement.
    private var band: Range<Int> = 0..<0
    /// Columns used for matching; excludes static sidebars, so their rows don't spoil the match.
    private var columns: Range<Int> = 0..<0
    private var body: [UInt32] = []

    var height: Int { band.isEmpty ? first.height : first.height - band.count + body.count / first.width }

    init(first: Frame, scrollbarGuard: Int = 0) {
        self.first = first
        self.last = first
        self.scrollbarGuard = scrollbarGuard
    }

    /// Returns the shift in pixels, 0 when nothing moved (end of page), nil when the frames don't line up.
    mutating func append(_ next: Frame, expectedShift: Int) -> Int? {
        guard next.width == first.width, next.height == first.height else { return nil }
        let w = first.width
        if band.isEmpty {
            guard let changed = Self.changedRect(first, next) else { return 0 }
            band = changed.rows
            let c = changed.columns
            columns = c.count > 3 * scrollbarGuard ? c.lowerBound..<(c.upperBound - scrollbarGuard) : c
            body = Array(first.pixels[band.lowerBound * w..<band.upperBound * w])
        }
        guard let shift = Self.findShift(hashes(last), hashes(next), expected: expectedShift) else { return nil }
        body += next.pixels[(band.upperBound - shift) * w..<band.upperBound * w]
        last = next
        return shift
    }

    /// Static header from the first frame, the stitched band, static footer from the last frame.
    func image() -> Frame {
        guard !band.isEmpty else { return first }
        let w = first.width
        let pixels = Array(first.pixels[..<(band.lowerBound * w)]) + body + Array(last.pixels[(band.upperBound * w)...])
        return Frame(width: w, height: pixels.count / w, pixels: pixels)
    }

    private func hashes(_ frame: Frame) -> [UInt64] {
        band.map { y in
            var h: UInt64 = 0xcbf29ce484222325
            let base = y * frame.width
            for x in columns { h = (h ^ UInt64(frame.pixels[base + x])) &* 0x100000001b3 }
            return h
        }
    }

    static func changedRect(_ a: Frame, _ b: Frame) -> (rows: Range<Int>, columns: Range<Int>)? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<a.height {
            let base = y * a.width
            for x in 0..<a.width where a.pixels[base + x] != b.pixels[base + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = y
            }
        }
        return maxY < 0 ? nil : (minY..<(maxY + 1), minX..<(maxX + 1))
    }

    /// Shift `dy` such that next[r] == prev[r + dy]. Repetitive content (blank lines) matches many shifts,
    /// so among good matches pick the one closest to how far we actually scrolled.
    static func findShift(_ prev: [UInt64], _ next: [UInt64], expected: Int) -> Int? {
        let n = prev.count
        func ratio(_ dy: Int) -> Double {
            var matches = 0
            for r in 0..<(n - dy) where next[r] == prev[r + dy] { matches += 1 }
            return Double(matches) / Double(n - dy)
        }
        if ratio(0) >= 0.98 { return 0 }
        let minOverlap = max(4, n / 20)
        guard n > minOverlap else { return nil }
        return (1...(n - minOverlap)).filter { ratio($0) >= 0.9 }.min { abs($0 - expected) < abs($1 - expected) }
    }
}

extension Frame {
    init(_ image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt32](repeating: 0, count: image.width * image.height)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func cgImage(colorSpace: CGColorSpace?) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

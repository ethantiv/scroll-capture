import CoreGraphics
import Foundation

/// Raw RGBA pixels, row 0 at the top.
struct Frame: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt32]
}

/// Glues consecutive screenshots of a scrolling view into one tall image.
/// Finds the vertical shift between every two frames, then appends only the rows that scrolled into view.
/// Shottr instead stacks strips by the commanded step and aligns only the last frame.
struct Stitcher {
    /// Each row is matched as this many vertical strips, so content that doesn't scroll with the page
    /// (a sticky sidebar, the overlay scroller, an animated ad) spoils only its own strips, not whole rows.
    static let strips = 16
    private let first: Frame
    private var last: Frame
    private var lastHashes: [UInt64] = []
    /// Rows that scroll (everything between a static header and footer); empty until the first movement.
    private var band: Range<Int> = 0..<0
    private var body: [UInt32] = []
    /// The latest frame that didn't line up. A retry captures the same scroll position again,
    /// so strips that differ between the two are a playing video or animation and are left out of matching.
    private var unmatched: Frame?
    /// Columns that no step has changed: a sticky sidebar (x.com's menu). Appended rows get a plain fill there
    /// instead of repeating the sidebar's bottom with every slice.
    private var stillColumns: [Bool]
    /// Diagnostics of the latest `append`: share of changed strips that match at the best shift, and share of strips that changed.
    private(set) var lastMatch = Match(shift: nil, best: 0, changed: 0)

    struct Match {
        let shift: Int?
        let best: Double
        let changed: Double
    }

    var height: Int { band.isEmpty ? first.height : first.height - band.count + body.count / first.width }

    init(first: Frame) {
        self.first = first
        self.last = first
        self.stillColumns = Array(repeating: true, count: first.width)
    }

    /// Returns the shift in pixels, 0 when nothing moved (end of page), nil when the frames don't line up.
    /// A nil leaves the stitched image as it was.
    mutating func append(_ next: Frame, expectedShift: Int) -> Int? {
        guard next.width == first.width, next.height == first.height else { return nil }
        let w = first.width
        let fresh = band.isEmpty
        if fresh {
            guard let rows = Self.changedRows(first, next) else { return 0 }
            band = rows
            body = Array(first.pixels[band.lowerBound * w..<band.upperBound * w])
            lastHashes = hashes(last)
        }
        let nextHashes = hashes(next)
        var match = Self.findShift(lastHashes, nextHashes, expected: expectedShift)
        // Only as a fallback: a frame captured while the page was still moving would mark every strip as animated.
        if match.shift == nil, let unmatched {
            let animated = zip(hashes(unmatched), nextHashes).map { $0 != $1 }
            match = Self.findShift(lastHashes, nextHashes, expected: expectedShift, ignoring: animated)
        }
        lastMatch = match
        unmatched = match.shift == nil ? next : nil
        // Keep the band only from a pair that really moved: one fixed by a spinner or a dropped scroll would spoil every later step.
        if fresh && (match.shift ?? 0) == 0 { band = 0..<0; body = []; return match.shift }
        guard let shift = match.shift else { return nil }
        if shift > 0 {
            // Up to 4 changed pixels is antialiasing noise: x.com's menu icons differ by single pixels between frames.
            let before = last.pixels, band = band
            for x in 0..<w where stillColumns[x] {
                stillColumns[x] = band.lazy.filter { before[$0 * w + x] != next.pixels[$0 * w + x] }.prefix(5).count < 5
            }
        }
        body += next.pixels[(band.upperBound - shift) * w..<band.upperBound * w]
        last = next
        lastHashes = nextHashes
        return shift
    }

    /// Static header from the first frame, the stitched band, static footer from the last frame.
    func image() -> Frame {
        guard !band.isEmpty else { return first }
        let w = first.width
        var body = body
        // The column's most common colour: the sidebar's background, or a border line running the whole height.
        for x in 0..<w where stillColumns[x] {
            var counts: [UInt32: Int] = [:]
            for y in band { counts[first.pixels[y * w + x], default: 0] += 1 }
            let fill = counts.max { $0.value < $1.value }!.key
            for i in stride(from: band.count * w + x, to: body.count, by: w) { body[i] = fill }
        }
        let pixels = Array(first.pixels[..<(band.lowerBound * w)]) + body + Array(last.pixels[(band.upperBound * w)...])
        return Frame(width: w, height: pixels.count / w, pixels: pixels)
    }

    /// One hash per (band row, strip), row-major.
    private func hashes(_ frame: Frame) -> [UInt64] {
        let w = frame.width, strips = Self.strips
        var result: [UInt64] = []
        result.reserveCapacity(band.count * strips)
        for y in band {
            for s in 0..<strips {
                var h: UInt64 = 0xcbf29ce484222325
                for x in (s * w / strips)..<((s + 1) * w / strips) { h = (h ^ UInt64(frame.pixels[y * w + x])) &* 0x100000001b3 }
                result.append(h)
            }
        }
        return result
    }

    static func changedRows(_ a: Frame, _ b: Frame) -> Range<Int>? {
        let w = a.width
        let changed = (0..<a.height).filter { y in a.pixels[y * w..<(y + 1) * w] != b.pixels[y * w..<(y + 1) * w] }
        guard let top = changed.first, let bottom = changed.last else { return nil }
        return top..<(bottom + 1)
    }

    /// Shift `dy` such that next[r] == prev[r + dy], scored by the share of matching strips.
    /// Blank or repetitive content matches many shifts equally well, so among the best pick the one
    /// closest to how far we scrolled. The page never moves further than that (it stops short at the end).
    /// Only strips that changed between the frames are scored: static wallpaper, a stuck sticky column or blank margins
    /// match at any shift and would drown out the content that actually scrolled (a page whose content column is
    /// under half the width never reached a whole-frame threshold). Strips flagged in `animated` aren't scored either.
    static func findShift(_ prev: [UInt64], _ next: [UInt64], expected: Int, ignoring animated: [Bool] = []) -> Match {
        let n = prev.count / strips
        let changed = zip(prev, next).map { $0 != $1 }
        let changedShare = Double(changed.lazy.filter { $0 }.count) / Double(max(prev.count, 1))
        if changedShare <= 0.02 { return Match(shift: 0, best: 1, changed: changedShare) }
        func score(_ dy: Int) -> Double {
            var hits = 0, total = 0
            for i in 0..<((n - dy) * strips) where changed[i] && (animated.isEmpty || !animated[i]) {
                total += 1
                if next[i] == prev[i + dy * strips] { hits += 1 }
            }
            return total == 0 ? 0 : Double(hits) / Double(total)
        }
        let maxShift = min(n - max(4, n / 20), expected + expected / 4)
        guard maxShift >= 1 else { return Match(shift: nil, best: 0, changed: changedShare) }
        let scores = (1...maxShift).map { (dy: $0, score: score($0)) }
        let best = scores.map(\.score).max() ?? 0
        guard best >= 0.6 else { return Match(shift: nil, best: best, changed: changedShare) }
        let shift = scores.filter { $0.score >= best - 0.02 }.min { abs($0.dy - expected) < abs($1.dy - expected) }?.dy
        return Match(shift: shift, best: best, changed: changedShare)
    }
}

extension Frame {
    /// Transparent pixels at the start of the bottom row: a window's rounded-corner radius in pixels.
    var cornerRadius: Int {
        pixels[((height - 1) * width)...].prefix { $0 >> 24 < 255 }.count
    }

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

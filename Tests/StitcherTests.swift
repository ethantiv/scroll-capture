import CoreGraphics
import Testing
@testable import ScrollCapture

@Suite struct StitcherTests {
    static let width = 32, viewport = 40, pageHeight = 130, header = 6, footer = 4

    /// Every page row is unique, like real content; header and footer stay put.
    static func pageRow(_ y: Int, _ x: Int) -> UInt32 { UInt32(truncatingIfNeeded: (y &* 2654435761) ^ (x &* 40503) ^ 0x55) }

    /// A window scrolled to `offset`. Options add things that don't scroll with the page:
    /// a static sidebar (`sidebarWidth` columns on the left), an overlay scroller (last 2) whose thumb follows the offset,
    /// and a fixed box floating over the middle of the content. `videoTime` adds a video that scrolls with the page
    /// (page rows 28..<70) and shows a different picture at every time.
    static func frame(offset: Int, sidebarWidth: Int = 0, scroller: Bool = false, fixedBox: Bool = false, videoTime: Int? = nil) -> Frame {
        var pixels: [UInt32] = []
        for y in 0..<(header + viewport + footer) {
            for x in 0..<width {
                switch y {
                case ..<header: pixels.append(0xAA00_0000 | UInt32(x))
                case (header + viewport)...: pixels.append(0xBB00_0000 | UInt32(x))
                default:
                    let row = y - header
                    if x < sidebarWidth { pixels.append(row % 5 == 0 ? 0xCC00_0000 | UInt32(row * 7 + x) : 0xCCFF_FFFF) }
                    else if scroller && x >= width - 2 { pixels.append(abs(row - offset / 3) < 4 ? 0xFFFF_FFFF : 0) }
                    else if fixedBox && (14..<18).contains(x) && (10..<20).contains(row) { pixels.append(0xDD00_0000 | UInt32(row)) }
                    else if let videoTime, (4..<28).contains(x), (28..<70).contains(row + offset) {
                        pixels.append(pageRow(row + offset + videoTime * 1000, x) ^ 0xEE00_0000)
                    }
                    else { pixels.append(pageRow(row + offset, x)) }
                }
            }
        }
        return Frame(width: width, height: header + viewport + footer, pixels: pixels)
    }

    static let offsets = [0, 25, 50, 75, 90, 90] // last real offset is clamped at pageHeight - viewport

    @Test func stitchesWholePageBetweenHeaderAndFooter() {
        var stitcher = Stitcher(first: Self.frame(offset: 0))
        let shifts = Self.offsets.dropFirst().map { stitcher.append(Self.frame(offset: $0), expectedShift: 25) }
        #expect(shifts == [25, 25, 25, 15, 0])

        var expected: [UInt32] = Array(Self.frame(offset: 0).pixels[..<(Self.header * Self.width)])
        for y in 0..<Self.pageHeight { for x in 0..<Self.width { expected.append(Self.pageRow(y, x)) } }
        expected += Self.frame(offset: 0).pixels.suffix(Self.footer * Self.width)
        #expect(stitcher.image() == Frame(width: Self.width, height: expected.count / Self.width, pixels: expected))
    }

    @Test func ignoresContentThatDoesNotScroll() {
        let frame = { Self.frame(offset: $0, sidebarWidth: 6, scroller: true, fixedBox: true) }
        var stitcher = Stitcher(first: frame(0))
        let shifts = Self.offsets.dropFirst().map { stitcher.append(frame($0), expectedShift: 25) }
        #expect(shifts == [25, 25, 25, 15, 0])
        let image = stitcher.image()
        #expect(image.height == Self.header + Self.pageHeight + Self.footer)
        for y in 0..<Self.pageHeight {
            #expect(image.pixels[(Self.header + y) * Self.width + 10] == Self.pageRow(y, 10))
            // x.com: the sticky sidebar shows once, then its background instead of its bottom with every slice.
            let sidebar = y < Self.viewport ? frame(0).pixels[(Self.header + y) * Self.width + 2] : 0xCCFF_FFFF
            #expect(image.pixels[(Self.header + y) * Self.width + 2] == sidebar)
        }
    }

    /// gry-online.pl: fixed wallpaper and a sticky column left under half the width scrolling.
    @Test func narrowScrollingColumnStillMatches() {
        let frame = { Self.frame(offset: $0, sidebarWidth: 18, scroller: true) }
        var stitcher = Stitcher(first: frame(0))
        let shifts = Self.offsets.dropFirst().map { stitcher.append(frame($0), expectedShift: 25) }
        #expect(shifts == [25, 25, 25, 15, 0])
        #expect(stitcher.image().height == Self.header + Self.pageHeight + Self.footer)
    }

    /// x.com: strips divide only the columns that scroll, the sidebar is left out; too narrow a span falls back to the whole width.
    @Test func changedColumnsSkipStaticSidebar() {
        let rows = Self.header..<(Self.header + Self.viewport)
        let columns = { (sidebar: Int) in
            Stitcher.changedColumns(Self.frame(offset: 0, sidebarWidth: sidebar), Self.frame(offset: 25, sidebarWidth: sidebar), rows: rows)
        }
        #expect(columns(6) == 6..<Self.width)
        #expect(columns(18) == 0..<Self.width)
    }

    @Test func unscrollableWindowGivesSingleFrame() {
        var stitcher = Stitcher(first: Self.frame(offset: 0))
        #expect(stitcher.append(Self.frame(offset: 0), expectedShift: 25) == 0)
        #expect(stitcher.image() == Self.frame(offset: 0))
    }

    @Test func cornerRadiusCountsTransparentPixelsInBottomRow() {
        let opaque = Frame(width: 10, height: 3, pixels: Array(repeating: 0xFF20_4060, count: 30))
        var corner = opaque
        for x in 0..<5 { corner.pixels[20 + x] = 0x0000_0000 }
        corner.pixels[25] = 0x80FF_FFFF // half-transparent edge pixel
        #expect(corner.cornerRadius == 6)
        #expect(opaque.cornerRadius == 0)
    }

    /// `Frame(CGImage)` and `cgImage` must agree on the byte order, and `cornerRadius` on where alpha sits.
    @Test func frameSurvivesCGImageRoundTrip() throws {
        var frame = Frame(width: 10, height: 3, pixels: Array(repeating: 0xFF20_4060, count: 30))
        for x in 0..<4 { frame.pixels[20 + x] = 0 }
        let back = Frame(try #require(frame.cgImage(colorSpace: nil)))
        #expect(back == frame)
        #expect(back.cornerRadius == 4)
    }

    /// A spinner changing a few rows before the page moves must not fix the scrolling band.
    @Test func bandComesFromAPairThatMoved() {
        var stitcher = Stitcher(first: Self.frame(offset: 0))
        var spinner = Self.frame(offset: 0)
        for i in (Self.header + 10) * Self.width..<(Self.header + 12) * Self.width { spinner.pixels[i] ^= 0xFF }
        #expect(stitcher.append(spinner, expectedShift: 25) == nil)
        #expect(stitcher.append(Self.frame(offset: 25), expectedShift: 25) == 25)
    }

    /// x.com: a video playing in the overlap spoils most strips at every shift, and retrying alone never helps.
    @Test func playingVideoIsLeftOutOnRetry() {
        var stitcher = Stitcher(first: Self.frame(offset: 0, videoTime: 0))
        let steps = [(25, 1), (25, 2), (50, 3), (50, 4), (75, 5)] // each failed step is captured again in place
        let shifts = steps.map { stitcher.append(Self.frame(offset: $0.0, videoTime: $0.1), expectedShift: 25) }
        #expect(shifts == [nil, 25, nil, 25, 25])
        let image = stitcher.image()
        #expect(image.height == Self.header + 75 + Self.viewport + Self.footer)
        for y in 0..<(75 + Self.viewport) {
            #expect(image.pixels[(Self.header + y) * Self.width + 1] == Self.pageRow(y, 1))
        }
    }

    /// Stripes or a table of equal rows match several shifts equally well: take the one closest to the scroll.
    @Test func repetitiveContentPicksExpectedShift() {
        let stripes = { (offset: Int) in
            Frame(width: Self.width, height: Self.viewport,
                  pixels: (0..<Self.viewport).flatMap { y in (0..<Self.width).map { Self.pageRow((y + offset) % 10, $0) } })
        }
        var stitcher = Stitcher(first: stripes(0))
        #expect(stitcher.append(stripes(25), expectedShift: 25) == 25)
    }

    @Test func unrelatedFrameIsRejectedAndKeepsStitchedImage() {
        var stitcher = Stitcher(first: Self.frame(offset: 0))
        #expect(stitcher.append(Self.frame(offset: 25), expectedShift: 25) == 25)
        let before = stitcher.image()
        var noise = Self.frame(offset: 25)
        noise.pixels = noise.pixels.enumerated().map { UInt32(truncatingIfNeeded: $0.offset &* 7919) ^ $0.element }
        #expect(stitcher.append(noise, expectedShift: 25) == nil)
        #expect(stitcher.image() == before)
    }
}

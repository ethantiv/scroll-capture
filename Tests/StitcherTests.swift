import Testing
@testable import ScrollCapture

@Suite struct StitcherTests {
    static let width = 12, viewport = 40, pageHeight = 130, header = 6, footer = 4

    /// Every page row is unique, like real content; header and footer stay put.
    static func pageRow(_ y: Int, _ x: Int) -> UInt32 { UInt32(truncatingIfNeeded: (y &* 2654435761) ^ (x &* 40503) ^ 0x55) }

    /// A window scrolled to `offset`: optional static sidebar (first 3 columns) and an overlay scroller (last 2) whose thumb follows the offset.
    static func frame(offset: Int, sidebar: Bool = false, scroller: Bool = false) -> Frame {
        var pixels: [UInt32] = []
        for y in 0..<(header + viewport + footer) {
            for x in 0..<width {
                switch y {
                case ..<header: pixels.append(0xAA00_0000 | UInt32(x))
                case (header + viewport)...: pixels.append(0xBB00_0000 | UInt32(x))
                default:
                    let row = y - header
                    if sidebar && x < 3 { pixels.append(0xCC00_0000 | UInt32(row * 7 + x)) }
                    else if scroller && x >= width - 2 { pixels.append(abs(row - offset / 3) < 4 ? 0xFFFF_FFFF : 0) }
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

    @Test func ignoresStaticSidebarAndMovingScroller() {
        var stitcher = Stitcher(first: Self.frame(offset: 0, sidebar: true, scroller: true), scrollbarGuard: 2)
        let shifts = Self.offsets.dropFirst().map {
            stitcher.append(Self.frame(offset: $0, sidebar: true, scroller: true), expectedShift: 25)
        }
        #expect(shifts == [25, 25, 25, 15, 0])
        let image = stitcher.image()
        #expect(image.height == Self.header + Self.pageHeight + Self.footer)
        for y in 0..<Self.pageHeight {
            #expect(image.pixels[(Self.header + y) * Self.width + 5] == Self.pageRow(y, 5))
        }
    }

    @Test func unscrollableWindowGivesSingleFrame() {
        var stitcher = Stitcher(first: Self.frame(offset: 0))
        #expect(stitcher.append(Self.frame(offset: 0), expectedShift: 25) == 0)
        #expect(stitcher.image() == Self.frame(offset: 0))
    }
}

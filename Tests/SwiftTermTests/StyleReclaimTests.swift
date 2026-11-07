import Foundation
import Testing
@testable import SwiftTerm

/// The number of style identifiers a terminal's cell arena hands out.
private let styleTableCapacity = Int(UInt16.max)

/// A truecolour foreground that no other index below 2^24 shares.
private func colour(_ index: Int) -> Attribute.Color {
    .trueColor(red: UInt8(index & 0xff), green: UInt8((index >> 8) & 0xff),
               blue: UInt8((index >> 16) & 0xff))
}

private func attribute(_ index: Int) -> Attribute {
    Attribute(fg: colour(index), bg: .defaultColor, style: .none)
}

private func appendForeground(_ index: Int, to bytes: inout [UInt8]) {
    bytes.append(contentsOf:
        "\u{1b}[38;2;\(index & 0xff);\((index >> 8) & 0xff);\((index >> 16) & 0xff)m".utf8)
}

/// One new foreground per index, with nothing printed.
private func penChanges(_ indices: Range<Int>) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(indices.count * 20)
    for index in indices {
        appendForeground(index, to: &bytes)
    }
    return bytes
}

/// One cell per index, each printed in its own foreground.
private func colouredCells(_ indices: Range<Int>) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(indices.count * 21)
    for index in indices {
        appendForeground(index, to: &bytes)
        bytes.append(UInt8(ascii: "x"))
    }
    return bytes
}

/// A terminal keeps colour once it has seen more distinct styles than its
/// cell arena has identifiers, because it reclaims the identifiers nothing
/// holds any more.
struct StyleReclaimTests {
    @Test func cellsKeepTheirColourOnceTheStyleTableIsFull() {
        let cols = 80
        let rows = 24
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows,
                                                             scrollback: 10)
        let total = styleTableCapacity + 500
        terminal.feed(byteArray: colouredCells(0..<total))

        // The screen shows the newest cells. Some were printed before the
        // table filled and keep their identifiers; the rest reuse released ones.
        let lastLine = (total - 1) / cols
        var wrong: [Int] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let index = (lastLine - rows + 1 + row) * cols + col
                guard index < total else { continue }
                if terminal.getCharData(col: col, row: row)?.attribute.fg != colour(index) {
                    wrong.append(index)
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) cells lost their colour, first \(wrong.prefix(5))")
        #expect(terminal.currentAttribute.fg == colour(total - 1))
    }

    @Test func restoredCursorKeepsItsColourAfterAReclaim() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        let saved = Attribute.Color.trueColor(red: 1, green: 2, blue: 250)
        // The saved style takes identifier 1 and no cell uses it, so the
        // reclaim releases it and the first new style afterwards reuses it.
        terminal.feed(text: "\u{1b}[38;2;1;2;250m\u{1b}7")
        terminal.feed(byteArray: penChanges(0..<styleTableCapacity + 1))
        terminal.feed(text: "N")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity))

        // DECRC interns the saved style again rather than using its old identifier.
        terminal.feed(text: "\u{1b}8R")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == saved)
    }

    @Test func reclaimOnTheAlternateScreenKeepsThePrimaryScreen() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        // These cells take the lowest identifiers, which a reclaim reuses first.
        let primary = (0..<40).map { Attribute.Color.trueColor(red: UInt8($0), green: 0, blue: 200) }
        var bytes: [UInt8] = []
        for column in primary.indices {
            bytes.append(contentsOf: "\u{1b}[38;2;\(column);0;200mp".utf8)
        }
        terminal.feed(byteArray: bytes)

        terminal.feed(text: "\u{1b}[?1049h")
        let flood = styleTableCapacity + primary.count
        terminal.feed(byteArray: penChanges(0..<flood))
        terminal.feed(text: "\u{1b}[Ha")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(flood - 1))

        terminal.feed(text: "\u{1b}[?1049l")
        let kept = primary.indices.map { terminal.getCharData(col: $0, row: 0)?.attribute.fg }
        #expect(kept == primary.map { Optional($0) })
    }

    @Test func erasedCellsKeepTheirBackgroundAfterAReclaim() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        let background = Attribute.Color.trueColor(red: 9, green: 8, blue: 7)
        // The background-only style takes identifier 1. Only the cached erase
        // cells hold it while the foreground changes, since nothing is printed.
        terminal.feed(text: "\u{1b}[48;2;9;8;7m")
        terminal.feed(byteArray: penChanges(0..<styleTableCapacity))
        terminal.feed(text: "n")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute ==
                Attribute(fg: colour(styleTableCapacity - 1), bg: background, style: .none))

        terminal.feed(text: "\u{1b}[2K")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute ==
                Attribute(fg: .defaultColor, bg: background, style: .none))
    }

    /// RIS replaces the normal buffer but keeps the arena, so the table stays
    /// full, and the next new style reclaims what the old buffer held.
    @Test func newColourAfterAFullResetOfAFullTable() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        terminal.feed(byteArray: penChanges(0..<styleTableCapacity))
        terminal.feed(text: "\u{1b}c")
        terminal.feed(byteArray: colouredCells(styleTableCapacity..<styleTableCapacity + 1))
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity))
    }

    @Test func snapshotCopiesFollowAReclaim() throws {
        let arena = CellArena(styleCapacity: 3)
        let first = try #require(arena.intern(attribute: attribute(1)))
        let second = try #require(arena.intern(attribute: attribute(2)))
        let third = try #require(arena.intern(attribute: attribute(3)))
        #expect(arena.intern(attribute: attribute(4)) == nil)
        let staleCopy = arena.snapshotCopy()

        var live = StyleIdentifierSet()
        live.insert(third)
        #expect(arena.canReclaimAttributes)
        #expect(arena.reclaimAttributes(keeping: live) == 2)
        // A copy made before the reclaim cannot catch up and is replaced.
        #expect(!staleCopy.synchronizeSnapshotPrefix(from: arena))
        #expect(!staleCopy.preservesEncoding(from: arena))

        let copy = arena.snapshotCopy()
        // The lowest released identifier is reused first, and the kept one
        // keeps both its attribute and its lookup.
        #expect(arena.intern(attribute: attribute(4)) == first)
        #expect(arena.attribute(for: third) == attribute(3))
        #expect(arena.intern(attribute: attribute(3)) == third)
        // A released attribute interns again under another free identifier.
        #expect(arena.intern(attribute: attribute(1)) == second)
        #expect(arena.intern(attribute: attribute(5)) == nil)

        // The copy misses the two reuses until it synchronizes.
        #expect(!copy.preservesEncoding(from: arena))
        #expect(copy.synchronizeSnapshotPrefix(from: arena))
        #expect(copy.preservesEncoding(from: arena))
        #expect(copy.attribute(for: first) == attribute(4))
        #expect(copy.attribute(for: second) == attribute(1))
        #expect(copy.attribute(for: third) == attribute(3))
    }

    @Test func aReclaimThatReleasesNothingWaitsBeforeTheNextScan() throws {
        let arena = CellArena(styleCapacity: 64)
        var live = StyleIdentifierSet()
        for index in 1...64 {
            let identifier = try #require(arena.intern(attribute: attribute(index)))
            live.insert(identifier)
        }
        #expect(arena.intern(attribute: attribute(65)) == nil)
        #expect(arena.canReclaimAttributes)
        #expect(arena.reclaimAttributes(keeping: live) == 0)
        #expect(arena.attributeEpoch == 0)

        // With 64 identifiers, 4 new attributes must arrive before the next scan.
        for index in 66...68 {
            #expect(arena.intern(attribute: attribute(index)) == nil)
            #expect(!arena.canReclaimAttributes)
        }
        #expect(arena.intern(attribute: attribute(69)) == nil)
        #expect(arena.canReclaimAttributes)
    }
}

#if os(macOS)
import AppKit

/// The renderer's copies and caches follow identifiers that a reclaim reuses.
@MainActor
struct StyleReclaimRenderTests {
    private func feed(_ view: TerminalView, _ bytes: [UInt8]) {
        view.withTerminal { $0.feed(byteArray: bytes) }
    }

    private func refresh(_ snapshot: TerminalSnapshot, from view: TerminalView) {
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
    }

    @Test func snapshotRowsDecodeReusedIdentifiers() throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4, scrollback: 2))
        let snapshot = TerminalSnapshot()
        // Hand out every identifier, then print with the last one.
        feed(view, penChanges(0..<styleTableCapacity) + Array("A".utf8))
        refresh(snapshot, from: view)

        // The next new colour reclaims, which replaces the snapshot's arena copy.
        feed(view, colouredCells(styleTableCapacity..<styleTableCapacity + 1))
        refresh(snapshot, from: view)
        var row = try #require(snapshot.rows.first)
        #expect(row.line.packedView(at: 0).attribute.fg == colour(styleTableCapacity - 1))
        #expect(row.line.packedView(at: 1).attribute.fg == colour(styleTableCapacity))

        // A later reuse in the same epoch reaches the copy when it synchronizes.
        feed(view, colouredCells(styleTableCapacity + 1..<styleTableCapacity + 2))
        refresh(snapshot, from: view)
        row = try #require(snapshot.rows.first)
        #expect(row.line.packedView(at: 2).attribute.fg == colour(styleTableCapacity + 1))
    }

    @Test func packedAttributeCacheFollowsAReclaim() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                                            ansiColors: view.withTerminal { $0.ansiColors },
                                            cols: 80)
        let builder = SnapshotTextBuilder()
        let arena = CellArena(styleCapacity: 1)
        let identifier = try #require(arena.intern(attribute: attribute(1)))
        let cell = try #require(arena.pack(styleID: identifier, scalar: 0x41, widthState: .narrow))
        let line = BufferLine(cols: 80, packedFill: PackedCell(), arena: arena)
        line.setPackedCell(cell, at: 0)
        let row = TerminalSnapshot.Row(source: line, borrowing: true)
        let before = foreground(builder.buildAttributedString(row: row, absoluteRow: 0,
                                                              context: context))

        // The cell keeps its raw value while its identifier changes meaning.
        #expect(arena.reclaimAttributes(keeping: StyleIdentifierSet()) == 1)
        #expect(arena.intern(attribute: attribute(2)) == identifier)
        let after = foreground(builder.buildAttributedString(row: row, absoluteRow: 0,
                                                             context: context))
        #expect(before != nil)
        #expect(after != nil)
        #expect(after != before)
    }

    private func foreground(_ info: ViewLineInfo) -> TTColor? {
        info.segments.first?.attributedString.attribute(.foregroundColor, at: 0,
                                                        effectiveRange: nil) as? TTColor
    }
}
#endif

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

/// A four-cell line whose first cells use `identifiers`, and whose other
/// cells use the default attribute.
private func styledLine(_ identifiers: [UInt16], in arena: CellArena) throws -> BufferLine {
    let line = BufferLine(cols: 4, packedFill: PackedCell(), arena: arena)
    for (column, identifier) in identifiers.enumerated() {
        let cell = try #require(arena.pack(styleID: identifier, scalar: 0x41,
                                           widthState: .narrow))
        line.setPackedCell(cell, at: column)
    }
    return line
}

/// A terminal keeps colour once it has seen more distinct styles than its
/// cell arena has identifiers, because it reclaims the identifiers nothing
/// holds any more.
struct StyleReclaimTests {
    /// Ways to discard many lines at once.
    enum Discard: Sendable {
        /// ED 3, which `clear` sends.
        case eraseSavedLines
        case clearScrollback
        case shrinkHistory
        case fullReset

        func apply(to terminal: Terminal) {
            switch self {
            case .eraseSavedLines:
                terminal.feed(text: "\u{1b}[3J")
            case .clearScrollback:
                terminal.clearScrollback()
            case .shrinkHistory:
                terminal.changeHistorySize(10)
            case .fullReset:
                terminal.feed(text: "\u{1b}c")
            }
        }
    }

    /// Discards that output can repeat for a few bytes a time, and that keep
    /// the alternate screen's cells.
    enum RepeatedDiscard: Sendable {
        /// Scrolls the top line into the scrollback, then erases it with ED 3.
        case eraseSavedLines
        /// RIS, which replaces the normal buffer and keeps the alternate one.
        case fullReset

        /// Prints one cell in the foreground `index`, then discards it.
        func cycle(_ index: Int, rows: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            switch self {
            case .eraseSavedLines:
                bytes.append(contentsOf: "\u{1b}[H".utf8)
                appendForeground(index, to: &bytes)
                bytes.append(contentsOf: "x\u{1b}[0m\u{1b}[\(rows)H\n\u{1b}[3J".utf8)
            case .fullReset:
                appendForeground(index, to: &bytes)
                bytes.append(contentsOf: "x\u{1b}c".utf8)
            }
            return bytes
        }
    }

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

    /// A reclaim can release a pen's background-only erase style while a cell
    /// keeps the pen. Selecting that pen again interns the erase style again,
    /// and that intern reclaims as the pen's own does.
    @Test func erasingWithAReselectedPenKeepsItsBackground() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 1000)
        let blue = Attribute.Color.ansi256(code: 4)
        // The pen takes identifier 1 and its erase style 2. Only the printed
        // cell holds either of them.
        terminal.feed(text: "\u{1b}[31;44mA\u{1b}[0m")
        // The cells hold every identifier except the erase style's, so the
        // reclaim the last of these starts releases only that one.
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity - 1))
        // ED 3 frees the scrollback, which held more identifiers than the
        // reclaim wait has left, so the next intern that finds the table
        // full reclaims at once. The pen itself is still interned.
        terminal.feed(text: "\u{1b}[3J")

        terminal.feed(text: "\u{1b}[0;31;44m\u{1b}[H\u{1b}[K")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.bg == blue)
        #expect(terminal.getCharData(col: 79, row: 0)?.attribute.bg == blue)
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

    /// A host's own call to `resetNormalBuffer()` replaces the normal buffer
    /// but keeps the old one on screen until the next screen switch, so a
    /// reclaim keeps what the old one holds.
    @Test func aReclaimKeepsTheColoursOfAReplacedBufferStillOnScreen() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        // These cells take the lowest identifiers, which a reclaim reuses first.
        let onScreen = 40
        terminal.feed(byteArray: colouredCells(0..<onScreen))
        terminal.resetNormalBuffer()

        // The pen fills the table. The first of the last 40 reclaims, and all
        // 40 take the lowest identifiers that reclaim released.
        terminal.feed(byteArray: penChanges(onScreen..<styleTableCapacity + onScreen))
        let kept = (0..<onScreen).map { terminal.getCharData(col: $0, row: 0)?.attribute.fg }
        #expect(kept == (0..<onScreen).map { Optional(colour($0)) })
    }

    /// Lines discarded from the scrollback leave the buffer's line slots, so
    /// the scan no longer counts them as holders.
    @Test(arguments: [Discard.eraseSavedLines, .clearScrollback])
    func discardedScrollbackReleasesItsStyles(discard: Discard) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 1000)
        // Every identifier goes to a cell, and the scrollback keeps them all.
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity))
        discard.apply(to: terminal)

        terminal.feed(text: "\u{1b}[H")
        terminal.feed(byteArray: colouredCells(styleTableCapacity..<styleTableCapacity + 1))
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity))
    }

    /// A reclaim that frees nothing makes the next one wait. Discarded lines
    /// count each distinct identifier they held toward the wait, so
    /// discarding a scrollback that holds nearly every one ends it, and the
    /// next new style reclaims at once.
    @Test(arguments: [Discard.eraseSavedLines, .clearScrollback, .shrinkHistory, .fullReset])
    func discardingLinesAfterAFruitlessReclaimReclaimsAtOnce(discard: Discard) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 1000)
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity))
        // The cells hold every identifier, so this reclaim frees nothing and
        // the style falls back to the default.
        terminal.feed(byteArray: colouredCells(styleTableCapacity..<styleTableCapacity + 1))
        discard.apply(to: terminal)

        terminal.feed(text: "\u{1b}[H")
        terminal.feed(byteArray: colouredCells(styleTableCapacity + 1..<styleTableCapacity + 2))
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity + 1))
    }

    /// Leaving the alternate screen counts each distinct identifier it held
    /// as one new style toward the wait, so leaving one that held more than
    /// the wait's 4,095 lets the next new style reclaim at once.
    @Test func leavingAnAlternateScreenThatHeldManyStylesReclaimsAtOnce() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 200, rows: 50, scrollback: 1000)
        let onAlternateScreen = 5000
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity - onAlternateScreen))
        // From the top, so the alternate screen keeps all its cells.
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[H")
        terminal.feed(byteArray: colouredCells(styleTableCapacity - onAlternateScreen..<styleTableCapacity))
        // Both screens together hold every identifier, so this reclaim frees nothing.
        terminal.feed(byteArray: colouredCells(styleTableCapacity..<styleTableCapacity + 1))

        // Leaving clears the alternate screen and frees what it held.
        terminal.feed(text: "\u{1b}[?1049l\u{1b}[H")
        #expect(!terminal.isCurrentBufferAlternate)
        terminal.feed(byteArray: colouredCells(styleTableCapacity + 1..<styleTableCapacity + 2))
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity + 1))
    }

    /// Output can enter the alternate screen, print one cell in a new colour
    /// and leave, over and over, for a few bytes each time. Each exit frees at
    /// most that one identifier, so it must not let the next new style scan
    /// both buffers.
    @Test func leavingAnAlternateScreenThatHeldOneStyleDoesNotScanOnEveryExit() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 1000)
        // The scrollback holds every identifier but the last, which only the
        // pen held before the reset to the default style.
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity - 1))
        terminal.feed(byteArray: penChanges(styleTableCapacity - 1..<styleTableCapacity))
        terminal.feed(text: "\u{1b}[0m")

        // The first new colour reclaims that identifier and starts an epoch.
        // Each cycle resets the pen, so only its cell holds the identifier.
        // If an exit ended the wait, every exit after it would let the next
        // colour reclaim it again and start another.
        var bytes: [UInt8] = []
        for cycle in 0..<100 {
            bytes.append(contentsOf: "\u{1b}[?1049h".utf8)
            appendForeground(styleTableCapacity + cycle, to: &bytes)
            bytes.append(contentsOf: "x\u{1b}[0m\u{1b}[?1049l".utf8)
        }
        terminal.feed(byteArray: bytes)
        #expect(terminal.buffer.cellArena.attributeEpoch == 1)
    }

    /// ED 3 on the normal screen and RIS both keep the alternate screen's
    /// cells, so output can fill that screen with styles once, then discard
    /// one cell in a new colour at a time, for a few bytes each. Each discard
    /// frees at most that one identifier, so it must not let the next new
    /// style scan both buffers.
    @Test(arguments: [RepeatedDiscard.eraseSavedLines, .fullReset])
    func discardsThatFreeOneStyleDoNotScanEveryTime(discard: RepeatedDiscard) {
        let rows = 220
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 300, rows: rows,
                                                             scrollback: 10)
        // Mode 47 leaves the alternate screen without clearing it. Its 66,000
        // cells hold every identifier but the last.
        terminal.feed(text: "\u{1b}[?47h\u{1b}[H")
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity - 1))
        terminal.feed(text: "\u{1b}[0m\u{1b}[?47l")
        #expect(!terminal.isCurrentBufferAlternate)

        // The first cycle takes the last identifier, and the second reclaims
        // it and starts an epoch. If a discard ended the wait, every cycle
        // after that would reclaim it again and start another.
        var bytes: [UInt8] = []
        for cycle in 0..<100 {
            bytes.append(contentsOf: discard.cycle(styleTableCapacity - 1 + cycle, rows: rows))
        }
        terminal.feed(byteArray: bytes)
        #expect(terminal.buffer.cellArena.attributeEpoch == 1)
    }

    @Test func discardedLinesCreditEachIdentifierOnceTowardTheWait() throws {
        let arena = CellArena(styleCapacity: 64)
        var live = StyleIdentifierSet()
        var identifiers: [UInt16] = []
        for index in 1...64 {
            let identifier = try #require(arena.intern(attribute: attribute(index)))
            live.insert(identifier)
            identifiers.append(identifier)
        }
        #expect(arena.intern(attribute: attribute(65)) == nil)
        #expect(arena.reclaimAttributes(keeping: live) == 0)
        #expect(arena.isWaitingToReclaim)

        // With 64 identifiers the wait is 4 new attributes. A line that holds
        // two identifiers counts as two, and discarding it again adds nothing.
        let twoStyles = try styledLine([identifiers[0], identifiers[1]], in: arena)
        arena.creditReclaimWait(discarding: twoStyles)
        arena.creditReclaimWait(discarding: twoStyles)
        // One new attribute makes three.
        #expect(arena.intern(attribute: attribute(66)) == nil)
        #expect(arena.isWaitingToReclaim)
        #expect(!arena.canReclaimAttributes)

        let oneMore = try styledLine([identifiers[2]], in: arena)
        arena.creditReclaimWait(discarding: oneMore)
        #expect(!arena.isWaitingToReclaim)
        #expect(arena.canReclaimAttributes)
    }

    /// Lines that scroll off the top of a full scrollback leave the buffer as
    /// discarded ones do, so the styles they held count toward the wait.
    /// Here every coloured line scrolls off before ED 3, which then discards
    /// only plain lines.
    @Test func scrollingColouredLinesOffAfterAFruitlessReclaimEndsTheWait() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 1000)
        terminal.feed(byteArray: colouredCells(0..<styleTableCapacity))
        // The cells hold every identifier, so this reclaim frees nothing and
        // the wait starts.
        terminal.feed(byteArray: colouredCells(styleTableCapacity..<styleTableCapacity + 1))
        // 1,100 plain lines push every coloured line off the top of the
        // 1,024 stored lines.
        terminal.feed(text: "\u{1b}[0m" + String(repeating: "plain\r\n", count: 1100))
        terminal.feed(text: "\u{1b}[3J\u{1b}[H")

        terminal.feed(byteArray: colouredCells(styleTableCapacity + 1..<styleTableCapacity + 2))
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity + 1))
    }

    /// Within one feed, a selected cell can be overwritten, its identifier
    /// released and reused, and the same character printed with it again.
    /// The raw cell is then unchanged although its colour is not.
    @Test func selectionClearsWhenAReclaimRecoloursASelectedCell() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24, scrollback: 10)
        let selection = SelectionService(terminal: terminal)
        // The selected cell takes identifier 1, then the pen fills the table.
        terminal.feed(byteArray: colouredCells(0..<1))
        terminal.feed(byteArray: penChanges(1..<styleTableCapacity))
        selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 1, row: 0))
        let before = try #require(selection.captureSelectedContent())

        // Printing over the cell in the default style releases identifier 1
        // at the next reclaim, and the new colour takes it.
        terminal.feed(text: "\u{1b}[H\u{1b}[0mx")
        terminal.feed(byteArray: penChanges(styleTableCapacity..<styleTableCapacity + 1))
        terminal.feed(text: "\u{1b}[Hx")
        #expect(terminal.getCharData(col: 0, row: 0)?.attribute.fg == colour(styleTableCapacity))

        selection.clearIfSelectedContentChanged(from: before)
        #expect(!selection.active)
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

    /// Rows that leave the screen go to a pool. One that returns after a
    /// reclaim, over a line that has not changed, is copied again through the
    /// current arena copy.
    @Test func rowsFromThePoolDecodeThroughTheCurrentArenaCopy() {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4, scrollback: 10))
        let snapshot = TerminalSnapshot()
        feed(view, Array("A\r\nB\r\nC\r\nD".utf8))
        refresh(snapshot, from: view)

        // Two rows go to the pool while C and D scroll into view.
        view.withTerminal { $0.resize(cols: 12, rows: 2) }
        refresh(snapshot, from: view)
        #expect(snapshot.rows.count == 2)

        // The last of these reclaims, which replaces the arena copy.
        feed(view, penChanges(0..<styleTableCapacity + 1))
        refresh(snapshot, from: view)

        // A and B come back into view, and none of the four lines changed.
        view.withTerminal { $0.resize(cols: 12, rows: 4) }
        refresh(snapshot, from: view)
        #expect(snapshot.rows.count == 4)
        let current = snapshot.rows.first.map { ObjectIdentifier($0.line.cellArena) }
        let arenas = snapshot.rows.map { ObjectIdentifier($0.line.cellArena) }
        #expect(arenas.allSatisfy { $0 == current })
    }

    /// Rows that leave the screen in the refresh that replaces the arena
    /// copy still decode through the old copy, so they are dropped rather
    /// than pooled, and the old copy is freed.
    @Test func rowsLeavingTheScreenAfterAReclaimDoNotKeepTheOldArenaCopy() {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4, scrollback: 10))
        let snapshot = TerminalSnapshot()
        feed(view, Array("A\r\nB\r\nC\r\nD".utf8))
        refresh(snapshot, from: view)
        weak var older = snapshot.rows.first?.line.cellArena
        #expect(older != nil)

        // The last of these reclaims, so the next refresh replaces the arena
        // copy while two of the four rows leave the screen.
        feed(view, penChanges(0..<styleTableCapacity + 1))
        view.withTerminal { $0.resize(cols: 12, rows: 2) }
        refresh(snapshot, from: view)
        #expect(snapshot.rows.count == 2)
        #expect(older == nil)
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

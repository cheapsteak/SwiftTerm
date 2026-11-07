import Testing
@testable import SwiftTerm

/// A terminal created wider than 80 columns has default tab stops across its
/// whole width, on both screens, and they behave like any other stop.
final class TabStopsAtCreationWidthTests {
    @Test(arguments: [120, 200])
    func tabPastColumn80StopsAtTheNextDefaultStop(cols: Int) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: 24)

        terminal.feed(text: "\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 96)

        terminal.feed(text: "\u{1b}[?1049h\u{1b}[1;89H\t")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer.x == 96)
    }

    @Test func stopsPastColumn80CanBeClearedAndSet() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 120, rows: 24)

        // TBC 0 at column 96 removes that stop, so a tab from 88 goes on to 104.
        terminal.feed(text: "\u{1b}[1;97H\u{1b}[0g\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 104)

        // HTS at column 100 adds a stop there.
        terminal.feed(text: "\u{1b}[1;101H\u{1b}H\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 100)

        // TBC 3 removes every stop, so a tab goes to the last column.
        terminal.feed(text: "\u{1b}[3g\u{1b}[1;1H\t")
        #expect(terminal.buffer.x == 119)
    }

    @Test func fullResetLeavesStopsPastColumn80OnBothScreens() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 120, rows: 24)

        // A control: RIS builds a new normal buffer at the full width, which
        // lays its stops whether or not creation did.
        terminal.feed(text: "\u{1b}c\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 96)

        // RIS rebuilds only the normal buffer, so the alternate screen keeps
        // the stops it was created with.
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[1;89H\t")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer.x == 96)
    }

    /// `setup()` applies a wider `options.cols` to an existing terminal, and
    /// lays stops across the columns it adds.
    @Test func setupAtAWiderWidthLaysStopsPastTheOldWidth() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.options.cols = 120
        terminal.setup()
        #expect(terminal.cols == 120)

        terminal.feed(text: "\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 96)

        terminal.feed(text: "\u{1b}[?1049h\u{1b}[1;89H\t")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer.x == 96)
    }

    @Test func resizeAfterCreationExtendsTheStops() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 120, rows: 24)
        terminal.feed(text: "\u{1b}[1;89H\t")
        #expect(terminal.buffer.x == 96)

        // Controls: `resize(cols:rows:)` lays stops from the last stop below
        // the old width, so it fills the gap even where creation left one.
        terminal.resize(cols: 200, rows: 24)
        terminal.feed(text: "\u{1b}[1;153H\t")
        #expect(terminal.buffer.x == 160)

        terminal.feed(text: "\u{1b}[?1049h\u{1b}[1;153H\t")
        #expect(terminal.buffer.x == 160)
    }
}

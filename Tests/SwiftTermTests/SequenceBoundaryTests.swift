import Testing
// A plain import, not `@testable`: the point is that an embedder can read this.
import SwiftTerm

private final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// An embedder that feeds a query of its own into a live terminal must not do
/// it while the program is part-way through a sequence, so the terminal says
/// when it is between sequences.
@Suite("Sequence boundary")
struct SequenceBoundaryTests {
    private static func makeTerminal() -> (Terminal, SilentDelegate) {
        let delegate = SilentDelegate()
        let terminal = Terminal(
            delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        return (terminal, delegate)
    }

    @Test("A fresh terminal and one after plain text are at a boundary")
    func groundIsABoundary() {
        let (terminal, delegate) = Self.makeTerminal()
        #expect(terminal.isAtSequenceBoundary)
        terminal.feed(text: "hello \u{1b}[1mworld\u{1b}[0m")
        #expect(terminal.isAtSequenceBoundary)
        withExtendedLifetime(delegate) {}
    }

    @Test(
        "Each unfinished sequence is not a boundary until it ends",
        arguments: [
            ("\u{1b}", "[1m"),
            ("\u{1b}[38;5;", "196m"),
            ("\u{1b}]0;half a ti", "tle\u{07}"),
            ("\u{1b}]8;;https://example.com/pa", "th\u{1b}\\"),
            ("\u{1b}Pq#0;2;0;0;0", "#0!10~\u{1b}\\"),
            ("\u{1b}_Ga=q,i=1;AAA", "A\u{1b}\\"),
        ])
    func unfinishedSequences(start: String, rest: String) {
        let (terminal, delegate) = Self.makeTerminal()
        terminal.feed(text: start)
        #expect(!terminal.isAtSequenceBoundary)
        terminal.feed(text: rest)
        #expect(terminal.isAtSequenceBoundary)
        withExtendedLifetime(delegate) {}
    }

    @Test("Half of a UTF-8 character is not a boundary")
    func partialCharacter() {
        let (terminal, delegate) = Self.makeTerminal()
        let euro: [UInt8] = [0xe2, 0x82, 0xac]
        terminal.feed(byteArray: Array(euro[0..<2]))
        #expect(!terminal.isAtSequenceBoundary)
        terminal.feed(byteArray: Array(euro[2...]))
        #expect(terminal.isAtSequenceBoundary)
        withExtendedLifetime(delegate) {}
    }
}

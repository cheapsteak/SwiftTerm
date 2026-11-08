#if os(macOS)
import AppKit
#endif
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
            // CSI with an intermediate byte: DECRQM waiting for its final.
            ("\u{1b}[?1$", "p"),
            // ESC with an intermediate byte: a G0 designation waiting for its
            // final.
            ("\u{1b}(", "B"),
            ("\u{1b}]0;half a ti", "tle\u{07}"),
            ("\u{1b}]8;;https://example.com/pa", "th\u{1b}\\"),
            ("\u{1b}Pq#0;2;0;0;0", "#0!10~\u{1b}\\"),
            ("\u{1b}_Ga=q,i=1;AAA", "A\u{1b}\\"),
            // SOS and PM, whose content is ignored but still ends at ST.
            ("\u{1b}Xstart of", " a string\u{1b}\\"),
            ("\u{1b}^start of", " a message\u{1b}\\"),
            // Between the ESC and the backslash of an ST: the string has
            // ended, and the ESC is waiting for its final byte.
            ("\u{1b}]0;title\u{1b}", "\\"),
            ("\u{1b}Pq#0!10~\u{1b}", "\\"),
            ("\u{1b}Xignored\u{1b}", "\\"),
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

    #if os(macOS)
    /// The view answers from any thread, so the thread that feeds it can ask
    /// once a feed has returned.
    @MainActor
    @Test("A view reports its terminal's boundary")
    func viewReportsTheBoundary() {
        let view = TerminalView(
            frame: CGRect(origin: .zero, size: CGSize(width: 400, height: 200)),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        #expect(view.isAtSequenceBoundary)
        view.feed(text: "\u{1b}]0;half a ti")
        #expect(!view.isAtSequenceBoundary)
        view.feed(text: "tle\u{07}")
        #expect(view.isAtSequenceBoundary)
    }
    #endif
}

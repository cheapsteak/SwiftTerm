import Testing
// A plain import, not `@testable`: the point is that an embedder can read these.
import SwiftTerm

private final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// `?1049h` saves the origin, wrap-around, reverse wrap-around and margin modes
/// with the cursor, and `?1049l` puts them back. An embedder that rebuilds the
/// screen elsewhere needs the primary buffer's saved values to send before its
/// own `?1049h`, so they are readable through the public API.
@Suite("Public saved modes")
struct PublicSavedModesTests {
    @Test("The modes ?1049h saves are readable on the primary buffer")
    func savedModesAreReadable() {
        let delegate = SilentDelegate()
        let terminal = Terminal(
            delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
        // A non-default value for each, set on the primary. Reverse wrap-around
        // goes on before autowrap goes off, because it only turns on while
        // autowrap is on.
        terminal.feed(text: "\u{1b}[?6h\u{1b}[?45h\u{1b}[?7l\u{1b}[?69h")
        terminal.feed(text: "\u{1b}[?1049h")
        // The alt program changes all four; the saved values must not follow.
        terminal.feed(text: "\u{1b}[?6l\u{1b}[?7h\u{1b}[?45l\u{1b}[?69l")
        terminal.feed(text: "\u{1b}[?1049l")

        #expect(!terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer.savedOriginMode)
        #expect(!terminal.buffer.savedWraparound)
        #expect(terminal.buffer.savedReverseWraparound)
        #expect(terminal.buffer.savedMarginMode)
    }
}

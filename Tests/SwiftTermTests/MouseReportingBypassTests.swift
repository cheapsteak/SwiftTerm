import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

private final class BypassCapturingDelegate: TerminalViewDelegate {
    var sentData: [[UInt8]] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sentData.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}

    /// A mouse report is an SGR sequence: ESC [ <
    var reports: [[UInt8]] {
        sentData.filter { $0.starts(with: [0x1b, 0x5b, 0x3c]) }
    }
}

struct MouseReportingBypassTests {
    private let esc = "\u{1b}"

    @MainActor private func waitForTerminalViewCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Builds a windowed view, optionally feeds `escapes`, and performs a
    /// left-button down/drag/up with `modifiers`. Returns the view and the
    /// delegate that captured everything the view sent.
    @MainActor private func drag(
        feeding escapes: String,
        allowReporting: Bool = true,
        optionBypasses: Bool,
        modifiers: NSEvent.ModifierFlags
    ) async -> (TerminalView, BypassCapturingDelegate) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let delegate = BypassCapturingDelegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = allowReporting
        view.optionBypassesMouseReporting = optionBypasses
        view.feed(text: "hello world\r\nsecond line\r\n" + escapes)
        await waitForTerminalViewCallbacks()
        delegate.sentData.removeAll()

        func event(_ type: NSEvent.EventType, x: CGFloat, number: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(
                    x: x * view.cellDimension.width,
                    y: view.frame.height - 0.5 * view.cellDimension.height
                ),
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        view.mouseDown(with: event(.leftMouseDown, x: 1.5, number: 1))
        view.mouseDragged(with: event(.leftMouseDragged, x: 5.5, number: 2))
        view.mouseUp(with: event(.leftMouseUp, x: 5.5, number: 3))
        await waitForTerminalViewCallbacks()
        return (view, delegate)
    }

    private var mouseOn: String { "\(esc)[?1002h\(esc)[?1006h" }

    @Test @MainActor func optionDragBypassesWhenEnabled() async {
        let (view, delegate) = await drag(
            feeding: mouseOn, optionBypasses: true, modifiers: [.option])
        #expect(delegate.reports.isEmpty)
        #expect(view.selection.active)
    }

    @Test @MainActor func optionDragReportsWhenDisabled() async {
        let (view, delegate) = await drag(
            feeding: mouseOn, optionBypasses: false, modifiers: [.option])
        #expect(!delegate.reports.isEmpty)
        #expect(!view.selection.active)
    }

    @Test @MainActor func shiftDragStillBypasses() async {
        for setting in [true, false] {
            let (_, delegate) = await drag(
                feeding: mouseOn, optionBypasses: setting, modifiers: [.shift])
            #expect(delegate.reports.isEmpty)
        }
    }

    @Test @MainActor func optionBypassesEvenUnderShiftCapture() async {
        let escapes = mouseOn + "\(esc)[>1s"
        let (_, shiftDelegate) = await drag(
            feeding: escapes, optionBypasses: true, modifiers: [.shift])
        #expect(!shiftDelegate.reports.isEmpty)
        let (_, optionDelegate) = await drag(
            feeding: escapes, optionBypasses: true, modifiers: [.option])
        #expect(optionDelegate.reports.isEmpty)
    }

    @Test @MainActor func noMouseModeDragSelectsLocally() async {
        let (view, delegate) = await drag(
            feeding: "", optionBypasses: false, modifiers: [])
        #expect(delegate.reports.isEmpty)
        #expect(view.selection.active)
    }
}
#endif

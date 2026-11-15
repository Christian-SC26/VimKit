#if os(macOS)
import AppKit
import Testing
@testable import VimKit

@MainActor
private func makeTextView(_ text: String) -> VimTextView {
    let runtime = VimRuntime()
    runtime.clipboard = InMemoryClipboard()
    let view = VimTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), options: VimOptions(), runtime: runtime)
    view.string = text
    view.setSelectedRange(NSRange(location: 0, length: 0))
    return view
}

@MainActor
private func press(_ view: VimTextView, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
    )!
    view.keyDown(with: event)
}

@MainActor
struct VimTextViewTests {
    @Test func normalModeCommandsEditTheView() {
        let view = makeTextView("hello world")
        press(view, "d", keyCode: 2)
        press(view, "w", keyCode: 13)
        #expect(view.string == "world")
        #expect(view.vim.text == "world")
    }

    @Test func normalModeDoesNotInsertText() {
        let view = makeTextView("abc")
        press(view, "z", keyCode: 6)
        press(view, "\u{1b}", keyCode: 53)
        #expect(view.string == "abc")
    }

    @Test func nativeTypingReachesTheEngine() {
        let view = makeTextView("ab")
        press(view, "a", keyCode: 0) // append after the cursor
        view.insertText("XY", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "aXYb")
        #expect(view.vim.text == "aXYb")
        press(view, "\u{1b}", keyCode: 53)
        #expect(view.vim.mode == .normal)
        press(view, "u", keyCode: 32)
        #expect(view.string == "ab")
    }

    @Test func visualSelectionIsShownInTheView() {
        let view = makeTextView("abcdef")
        press(view, "v", keyCode: 9)
        press(view, "l", keyCode: 37)
        press(view, "l", keyCode: 37)
        #expect(view.selectedRange() == NSRange(location: 0, length: 3))
    }

    @Test func mouseSelectionIsSentToTheEngine() {
        let view = makeTextView("one two")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(view.vim.cursorOffset == 4)
        press(view, "x", keyCode: 7)
        #expect(view.string == "one wo")
    }

    @Test func settingStringResetsTheEngine() {
        let view = makeTextView("first")
        view.string = "second text"
        #expect(view.vim.text == "second text")
    }

    @Test func disabledViewIsPlainTextView() {
        let view = makeTextView("abc")
        view.isVimEnabled = false
        view.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "Zabc")
        view.isVimEnabled = true
        #expect(view.vim.text == "Zabc")
    }

    @Test func russianLayoutKeyEvent() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "о", charactersIgnoringModifiers: "о", isARepeat: false, keyCode: 38
        )!
        let key = VimKeyEvent(event)
        #expect(key?.key == "о")
        #expect(key?.code == "KeyJ")
    }

    @Test func characterRectsExist() {
        let view = makeTextView("ab\ncd")
        let a = view.characterRect(at: 0)
        let c = view.characterRect(at: 3)
        #expect(a != nil && c != nil)
        if let a, let c { #expect(c.minY > a.minY) }
    }
}

@MainActor
struct KeyboardLayoutTests {
    @Test func russianLayoutRunsCommandsByPhysicalKey() {
        let view = makeTextView("a\nb\nc")
        view.vim.setCursor(line: 2, column: 0)
        press(view, "п", keyCode: 5)
        press(view, "п", keyCode: 5)
        #expect(view.vim.cursor.line == 0)
        press(view, "о", keyCode: 38)
        #expect(view.vim.cursor.line == 1)
    }
}
#endif

import Foundation
import Testing
@testable import VimCore

/// Records what the engine asks a view to do.
@MainActor
final class RecordingDelegate: VimEngineDelegate {
    var mirror = ""
    var saves = 0
    var commands: [VimExCommand] = []

    func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {
        mirror = (mirror as NSString).replacingCharacters(in: range, with: text)
    }
    func vimEngineDidRequestSave(_ engine: VimEngine) { saves += 1 }
    func vimEngine(_ engine: VimEngine, didRun command: VimExCommand) { commands.append(command) }
}

@MainActor
private func makeEngine(_ text: String, line: Int = 0, column: Int = 0) -> VimEngine {
    let runtime = VimRuntime()
    runtime.clipboard = InMemoryClipboard()
    let engine = VimEngine(text: text, runtime: runtime)
    engine.setCursor(line: line, column: column)
    return engine
}

@MainActor
struct MotionTests {
    @Test func wordMotions() {
        let vim = makeEngine("one two three")
        vim.feed("w")
        #expect(vim.cursor == VimPosition(line: 0, column: 4))
        vim.feed("e")
        #expect(vim.cursor == VimPosition(line: 0, column: 6))
        vim.feed("b")
        #expect(vim.cursor == VimPosition(line: 0, column: 4))
        vim.feed("$")
        #expect(vim.cursor == VimPosition(line: 0, column: 12))
        vim.feed("0")
        #expect(vim.cursor == VimPosition(line: 0, column: 0))
    }

    @Test func linesAndCounts() {
        let vim = makeEngine("a\nb\nc\nd\ne")
        vim.feed("3j")
        #expect(vim.cursor.line == 3)
        vim.feed("gg")
        #expect(vim.cursor.line == 0)
        vim.feed("G")
        #expect(vim.cursor.line == 4)
        vim.feed("2G")
        #expect(vim.cursor.line == 1)
    }

    @Test func findCharacterAndRepeat() {
        let vim = makeEngine("a,b,c,d")
        vim.feed("f,")
        #expect(vim.cursor.column == 1)
        vim.feed(";;")
        #expect(vim.cursor.column == 5)
        vim.feed(",")
        #expect(vim.cursor.column == 3)
    }

    @Test func matchingBracket() {
        let vim = makeEngine("call(a, [b], c)")
        vim.feed("f(%")
        #expect(vim.cursor.column == 14)
        vim.feed("%")
        #expect(vim.cursor.column == 4)
    }

    @Test func searchForwardAndNext() {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        let vim = VimEngine(text: "foo bar\nbar foo\nfoo", runtime: runtime)
        vim.feed("/foo<CR>")
        #expect(vim.cursor == VimPosition(line: 1, column: 4))
        vim.feed("n")
        #expect(vim.cursor == VimPosition(line: 2, column: 0))
        vim.feed("N")
        #expect(vim.cursor == VimPosition(line: 1, column: 4))
        // vim.js applies the highlight on a 50 ms timer; under load (CI) it may not get to run.
        runtime.firePendingTimers()
        #expect(vim.searchMatches().count == 3)
        vim.feed("<Esc>")
        #expect(vim.searchMatches().isEmpty)
    }

    @Test func starSearchesWordUnderCursor() {
        let vim = makeEngine("alpha beta alpha")
        vim.feed("*")
        #expect(vim.cursor.column == 11)
    }
}

@MainActor
struct EditingTests {
    @Test func deleteWordAndLine() {
        let vim = makeEngine("one two three\nsecond")
        vim.feed("dw")
        #expect(vim.text == "two three\nsecond")
        vim.feed("dd")
        #expect(vim.text == "second")
    }

    @Test func changeInnerWord() {
        let vim = makeEngine("hello world")
        vim.feed("wciwthere<Esc>")
        #expect(vim.text == "hello there")
        #expect(vim.mode == .normal)
    }

    @Test func textObjects() {
        let vim = makeEngine("f(a, \"quoted text\", b)")
        vim.feed("fqci\"x<Esc>")
        #expect(vim.text == "f(a, \"x\", b)")
        vim.feed("di(")
        #expect(vim.text == "f()")
    }

    @Test func yankAndPut() {
        let vim = makeEngine("line one\nline two")
        vim.feed("yyjp")
        #expect(vim.text == "line one\nline two\nline one")
        vim.feed("ggyiwP")
        #expect(vim.text == "lineline one\nline two\nline one")
    }

    @Test func namedRegisters() {
        let vim = makeEngine("first\nsecond")
        vim.feed("\"ayyj\"ap")
        #expect(vim.text == "first\nsecond\nfirst")
    }

    @Test func dotRepeatsInsertAndOperators() {
        let vim = makeEngine("a b c d")
        vim.feed("x.")
        #expect(vim.text == "b c d")
        vim.feed("A!<Esc>")
        vim.feed("0.")
        #expect(vim.text == "b c d!!")
    }

    @Test func countedInsert() {
        let vim = makeEngine("")
        vim.feed("3ia<Esc>")
        #expect(vim.text == "aaa")
    }

    @Test func visualModes() {
        let vim = makeEngine("abc\ndef\nghi")
        vim.feed("vlld")
        #expect(vim.text == "\ndef\nghi")
        vim.feed("jVd")
        #expect(vim.text == "\nghi")
    }

    @Test func visualBlockInsert() {
        let vim = makeEngine("aa\nbb\ncc")
        vim.feed("<C-v>jjI- <Esc>")
        #expect(vim.text == "- aa\n- bb\n- cc")
    }

    @Test func indentOperators() {
        let vim = makeEngine("a\nb")
        vim.feed(">>j>>")
        #expect(vim.text == "    a\n    b")
        vim.feed("<<")
        #expect(vim.text == "    a\nb")
    }

    @Test func joinAndCase() {
        let vim = makeEngine("hello\nworld")
        vim.feed("J")
        #expect(vim.text == "hello world")
        vim.feed("0g~iw")
        #expect(vim.text == "HELLO world")
    }

    @Test func macros() {
        let vim = makeEngine("1\n2\n3")
        vim.feed("qaA.<Esc>jq2@a")
        #expect(vim.text == "1.\n2.\n3.")
    }

    @Test func replaceMode() {
        let vim = makeEngine("abcdef")
        vim.feed("Rxy<Esc>")
        #expect(vim.text == "xycdef")
    }
}

@MainActor
struct UndoTests {
    @Test func undoRedo() {
        let vim = makeEngine("one two")
        vim.feed("dw")
        #expect(vim.text == "two")
        vim.feed("u")
        #expect(vim.text == "one two")
        vim.feed("<C-r>")
        #expect(vim.text == "two")
    }

    @Test func changeAndInsertIsOneUndoStep() {
        let vim = makeEngine("one two")
        vim.feed("cwONE<Esc>")
        #expect(vim.text == "ONE two")
        vim.feed("u")
        #expect(vim.text == "one two")
    }

    @Test func nativeTypingJoinsTheInsertSession() {
        let vim = makeEngine("ab")
        vim.feed("a")
        // The text view typed these characters itself.
        vim.replaceCharacters(in: NSRange(location: 1, length: 0), with: "X")
        vim.replaceCharacters(in: NSRange(location: 2, length: 0), with: "Y")
        vim.setSelections([VimSelection(anchor: 3, head: 3)])
        vim.feed("<Esc>")
        #expect(vim.text == "aXYb")
        vim.feed("u")
        #expect(vim.text == "ab")
    }
}

@MainActor
struct ExCommandTests {
    @Test func substitute() {
        let vim = makeEngine("a-a\na-a")
        vim.feed(":%s/a/b/g<CR>")
        #expect(vim.text == "b-b\nb-b")
    }

    @Test func executeAPI() {
        let vim = makeEngine("x\ny\nz")
        vim.execute(":2d")
        #expect(vim.text == "x\nz")
    }

    @Test func saveGoesToDelegate() {
        let vim = makeEngine("text")
        let delegate = RecordingDelegate()
        vim.delegate = delegate
        vim.feed(":w<CR>")
        #expect(delegate.saves == 1)
    }

    @Test func customExCommand() {
        let vim = makeEngine("text")
        var received: VimExCommand?
        vim.defineEx("greet", prefix: "gr") { received = $0 }
        vim.feed(":greet world<CR>")
        #expect(received?.name == "greet")
        #expect(received?.argString.trimmingCharacters(in: .whitespaces) == "world")
    }

    @Test func commandLineStatus() {
        let vim = makeEngine("text")
        vim.feed(":s/x")
        #expect(vim.status.commandLine?.prefix == ":")
        #expect(vim.status.commandLine?.text == "s/x")
        vim.feed("<Esc>")
        #expect(vim.status.commandLine == nil)
        #expect(vim.text == "text")
    }

    @Test func mappings() {
        let vim = makeEngine("abc")
        vim.runtime.execute("imap jk <Esc>")
        vim.feed("ix")
        vim.feed("jk")
        #expect(vim.mode == .normal)
        #expect(vim.text == "xabc")
        vim.runtime.execute("nnoremap Y y$")
        vim.feed("lYP")
        #expect(vim.text == "xabcabc")
    }
}

@MainActor
struct StatusAndMirrorTests {
    @Test func modesAreReported() {
        let vim = makeEngine("abc")
        #expect(vim.mode == .normal)
        vim.feed("i")
        #expect(vim.mode == .insert)
        vim.feed("<Esc>v")
        #expect(vim.mode == .visual)
        vim.feed("<Esc>V")
        #expect(vim.mode == .visualLine)
        vim.feed("<Esc><C-v>")
        #expect(vim.mode == .visualBlock)
        vim.feed("<Esc>R")
        #expect(vim.mode == .replace)
        vim.feed("<Esc>")
        #expect(vim.mode == .normal)
    }

    @Test func pendingKeys() {
        let vim = makeEngine("abc")
        vim.feed("2d")
        #expect(vim.status.pendingKeys == "2d")
        vim.feed("<Esc>")
        #expect(vim.status.pendingKeys == "")
    }

    @Test func delegateMirrorsEveryChange() {
        let text = "alpha beta\ngamma\ndelta"
        let vim = makeEngine(text)
        let delegate = RecordingDelegate()
        delegate.mirror = text
        vim.delegate = delegate
        vim.feed("dwjddp:%s/a/A/g<CR>u<C-r>ixyz<Esc>3ia<Esc>")
        #expect(delegate.mirror == vim.text)
    }

    @Test func nonLatinLayoutUsesPhysicalKeys() {
        let vim = makeEngine("a\nb\nc")
        // Russian layout: the J key produces "о".
        vim.handle(VimKeyEvent(key: "о", code: "KeyJ"))
        #expect(vim.cursor.line == 1)
        // Shift+D produces "В".
        vim.handle(VimKeyEvent(key: "В", code: "KeyD", shift: true))
        #expect(vim.text == "a\n\nc")
    }

    @Test func normalModeSwallowsTextButNotCommandShortcuts() {
        let vim = makeEngine("abc")
        #expect(vim.handle(VimKeyEvent(key: "q", code: "KeyQ")) == true)
        vim.feed("<Esc>")
        #expect(vim.handle(VimKeyEvent(key: "c", code: "KeyC", command: true)) == false)
        vim.feed("i")
        #expect(vim.handle(VimKeyEvent(key: "z", code: "KeyZ")) == false)
    }

    @Test func clipboardRegister() {
        let vim = makeEngine("copy me")
        vim.feed("\"+yiw")
        #expect(vim.runtime.clipboard.string == "copy")
    }

    @Test func utf16Offsets() {
        let vim = makeEngine("😀 word")
        vim.feed("wdw")
        #expect(vim.text == "😀 ")
        #expect(vim.cursorOffset == 2)
    }
}

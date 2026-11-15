import Foundation
import Testing
@testable import VimCore

/// Vim's registers beyond codemirror-vim's: the clipboard, file names,
/// expressions, :let, :registers, macros as text, <C-r> in the command line.
@MainActor
struct RegisterTests {
    let runtime = VimRuntime()
    let clipboard = InMemoryClipboard()

    init() { runtime.clipboard = clipboard }

    func editor(_ text: String) -> VimEngine { VimEngine(text: text, runtime: runtime) }

    @Test func clipboardRegisters() {
        let vim = editor("one\ntwo")
        vim.feed("\"*yy")
        #expect(clipboard.string == "one\n", "* is the clipboard too")
        clipboard.string = "pasted"
        vim.feed("j\"+p")
        #expect(vim.text == "one\ntpastedwo", "text from another app is characterwise")
        clipboard.string = "line\n"
        vim.feed("\"*P")
        #expect(vim.text == "one\nline\ntpastedwo", "…unless it ends with a newline")
        vim.feed(":set clipboard=unnamed<CR>gg\"_ddyy")
        #expect(clipboard.string == "line\n", "clipboard=unnamed: yanks go to the clipboard")
        clipboard.string = "outside"
        vim.feed("p")
        #expect(vim.text.hasPrefix("loutsideine\n"), "…and p pastes from it")
    }

    @Test func fileNameRegisters() {
        let vim = editor("x")
        vim.fileName = "src/main.swift"
        vim.alternateFileName = "README.md"
        vim.feed("\"%p\"#P")
        #expect(vim.text == "xsrc/main.swifREADME.mdt")
        vim.feed("\"=expand('%:t:r')<CR>p")
        #expect(vim.text.contains("main"))
        vim.feed("\"%yy")
        #expect(vim.status.message?.contains("E354") == true, "% is read-only")
    }

    @Test func expressionRegister() {
        let vim = editor("x")
        vim.feed("\"=6*7<CR>p")
        #expect(vim.text == "x42")
        vim.feed("A <C-r>=10/3 . '|' . 7/2.0 . '|' . toupper('ok')<CR><Esc>")
        #expect(vim.text == "x42 3|3.5|OK")
        vim.feed("o<C-r>=strftime('%Y')<CR><Esc>")
        #expect(vim.text.hasSuffix("\n\(Calendar.current.component(.year, from: Date()))"))
        vim.feed("\"=1/0<CR>")
        #expect(vim.status.message == "E1154: Divide by zero" && vim.status.messageIsError)
        vim.feed(":echo printf('%03d', 7) line('$') strlen(@\")<CR>")
        #expect(vim.status.message == "007 2 0")
    }

    @Test func letAndRegistersCommand() {
        let vim = editor("abc def")
        vim.execute("let @a = 'one'")
        vim.execute("let @A = ' two'")
        vim.execute("let @b = \"line\\n\"")
        #expect(runtime.register("a") == VimRegister(text: "one two"))
        #expect(runtime.register("b") == VimRegister(text: "line\n", kind: .linewise))
        vim.feed("yiw")
        vim.execute("registers")
        let lines = (vim.status.message ?? "").components(separatedBy: "\n")
        #expect(lines.first == "Type Name Content")
        #expect(lines.contains("  c  \"\"   abc"))
        #expect(lines.contains("  c  \"0   abc"))
        #expect(lines.contains("  l  \"b   line^J"))
        vim.execute("display a")
        #expect(vim.status.message?.contains("\"b") == false)
        // @/ sets the search: n finds it, the cursor stays until then.
        vim.feed("0")
        vim.execute("let @/ = 'def'")
        #expect(vim.status.cursorOffset == 0)
        vim.feed("n")
        #expect(vim.status.cursorOffset == 4)
    }

    @Test func numberedRegisters() {
        let vim = editor("a\nb\nc\nd\n(x) y")
        vim.feed("\"zdd")
        #expect(runtime.register("1")?.text == "a\n", "a named delete of lines also goes to \"1")
        vim.feed("dddddd")
        vim.feed("\"1p..")
        #expect(vim.text == "(x) y\nd\nc\nb", "\"1p.. pastes \"1, \"2, \"3")
        vim.feed("ggd%")
        #expect(runtime.register("1")?.text == "(x)", "d% goes to \"1 (Vi compatible)")
        #expect(runtime.register("-")?.text == "(x)")
    }

    @Test func visualPutKeepsOrSwaps() {
        let vim = editor("aa bb")
        vim.feed("yiwwviwP0viwP")
        #expect(vim.text == "aa aa", "visual P keeps the register")
        let other = editor("aa bb")
        other.feed("yiwwviwp0viwp")
        #expect(other.text == "bb aa", "visual p puts the replaced text in it")
    }

    @Test func macrosAreKeyText() {
        let vim = editor("a\nb\nc")
        vim.feed("qqA;<Esc>jq")
        #expect(runtime.register("q") == VimRegister(text: "A;<Esc>j"))
        vim.feed("@q")
        #expect(vim.text == "a;\nb;\nc")
        // Paste the macro, edit it, yank it back and run it.
        vim.feed("Go<Esc>\"qp")
        #expect(vim.text.hasSuffix("\nA;<Esc>j"))
        vim.feed(":s/;/!/<CR>0\"qy$")
        vim.feed("ggjj@q")
        #expect(vim.text.hasPrefix("a;\nb;\nc!\n"))
        // Ex commands and searches inside a macro.
        let ex = editor("aa\nab\nac")
        ex.feed("qw:s/a/X/<CR>jq@w")
        #expect(ex.text == "Xa\nXb\nac")
        let search = editor("x a\nx a\nx a")
        search.feed("qe/a<CR>rBq@e")
        #expect(search.text == "x B\nx B\nx a")
        // qQ appends to q.
        let append = editor("1\n2\n3\n4")
        append.feed("qaA.<Esc>qqAjq")
        #expect(runtime.register("a")?.text == "A.<Esc>j")
    }

    @Test func macroStopsWhenAMotionFails() {
        let vim = editor("1\n2\n3")
        vim.feed("qqA.<Esc>jq999@q")
        #expect(vim.text == "1.\n2.\n3.")
        let recursive = editor("1\n2\n3")
        recursive.feed("qwq")
        recursive.feed("qwA,<Esc>j@wq@w")
        #expect(recursive.text == "1,\n2,\n3,")
    }

    @Test func dotAfterMacroRepeatsItsLastChange() {
        let vim = editor("")
        vim.feed("qa$alarry.<Esc>acurly.<Esc>qamoe.<Esc>@a.")
        #expect(vim.text == "larry.curly.moe.larry.curly.curly.")
    }

    @Test func ctrlRInCommandLine() {
        let vim = editor("foo bar\nbaz")
        vim.feed("yiw:s/<C-r>\"/X/<CR>")
        #expect(vim.text == "X bar\nbaz")
        vim.feed("w:s/<C-r><C-w>/Y/<CR>")
        #expect(vim.text == "X Y\nbaz")
        vim.feed("j/<C-r>0<CR>")
        #expect(vim.status.commandLine == nil)
    }

    @Test func hostRegisterAPI() {
        let vim = editor("x")
        #expect(runtime.setRegister("k", to: VimRegister(text: "kept\n", kind: .linewise)))
        vim.feed("\"kp")
        #expect(vim.text == "x\nkept")
        #expect(!runtime.setRegister(".", to: VimRegister(text: "no")))
        #expect(runtime.registerNames.contains("k"))
        runtime.setRegister("k", to: nil)
        #expect(runtime.register("k") == nil)
        // Registers are shared by the runtime's editors.
        runtime.setRegister("m", to: VimRegister(text: "shared"))
        let other = editor("")
        other.feed("\"mp")
        #expect(other.text == "shared")
    }

    @Test func lineNumberOptions() {
        let vim = editor("x")
        #expect(vim.vimOption("number") as? Bool == false)
        vim.feed(":set nu rnu<CR>")
        #expect(vim.vimOption("number") as? Bool == true)
        #expect(vim.vimOption("relativenumber") as? Bool == true)
        vim.feed(":set nonu<CR>")
        #expect(vim.vimOption("number") as? Bool == false)
        #expect(vim.setVimOption("number", true))
        #expect(vim.vimOption("nu") as? Bool == true)
        #expect(vim.vimOption("numberwidth") as? Int == 4)
    }
}

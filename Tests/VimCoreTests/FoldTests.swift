import Foundation
import Testing
@testable import VimCore

@MainActor
struct FoldTests {
    static let code = """
    func a() {
      if x {
        one
      }
      two
    }

    func b() {
      three
    }
    """

    /// Hidden lines as 0-based [first, last] pairs.
    func hiddenLines(_ vim: VimEngine) -> [[Int]] {
        let text = vim.text as NSString
        func line(_ offset: Int) -> Int {
            text.substring(to: offset).filter { $0 == "\n" }.count
        }
        return vim.folds.map { fold in
            let end = fold.hiddenRange.upperBound
            let last = end == text.length ? line(end) : line(end) - 1
            return [line(fold.hiddenRange.location), last]
        }
    }

    func engine(_ text: String = code) -> VimEngine {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        return VimEngine(text: text, runtime: runtime)
    }

    @Test func closeAndOpen() {
        let vim = engine()
        vim.feed("zc")
        #expect(hiddenLines(vim) == [[1, 5]], "the block with its closing brace")
        #expect(vim.folds.first?.lineCount == 5)
        vim.feed("zo")
        #expect(vim.folds.isEmpty)
        vim.feed("za")
        #expect(hiddenLines(vim) == [[1, 5]])
        vim.feed("za")
        #expect(vim.folds.isEmpty)
    }

    @Test func jAndKSkipClosedFolds() {
        let vim = engine()
        vim.feed("zcj")
        #expect(vim.cursor.line == 6)
        vim.feed("k")
        #expect(vim.cursor.line == 0)
    }

    @Test func zcInsideABlockClosesItAndMovesToItsHeader() {
        let vim = engine()
        vim.setCursor(line: 2, column: 4)
        vim.feed("zc")
        #expect(hiddenLines(vim) == [[2, 3]])
        #expect(vim.cursor.line == 1)
        vim.feed("zc")
        #expect(hiddenLines(vim) == [[1, 5]], "a second zc closes the enclosing block")
        #expect(vim.cursor.line == 0)
        vim.feed("zo")
        #expect(hiddenLines(vim) == [[2, 3]], "the inner fold stays closed")
    }

    @Test func closeAllOpenAllDeleteAll() {
        let vim = engine()
        vim.feed("zM")
        #expect(hiddenLines(vim) == [[1, 5], [8, 9]])
        vim.feed("zR")
        #expect(vim.folds.isEmpty)
        vim.feed("zM")
        vim.feed("zE")
        #expect(vim.folds.isEmpty)
        vim.feed("zc")
        #expect(hiddenLines(vim) == [[1, 5]], "zE deleted the folds; zc makes a new one")
    }

    @Test func zfFoldsAnyLines() {
        let vim = engine()
        vim.setCursor(line: 4, column: 0)
        vim.feed("zf2j")
        #expect(hiddenLines(vim) == [[5, 6]])
        #expect(vim.cursor.line == 4)
        vim.feed("zd")
        #expect(vim.folds.isEmpty)
        vim.feed("Vjzf")
        #expect(hiddenLines(vim) == [[5, 5]])
        #expect(vim.mode == .normal)
    }

    @Test func searchOpensTheFoldItLandsIn() {
        let vim = engine()
        vim.feed("zM/three<CR>")
        #expect(vim.cursor == VimPosition(line: 8, column: 2))
        #expect(hiddenLines(vim) == [[1, 5]])
    }

    @Test func editsMoveFoldsOrDeleteThem() {
        let vim = engine()
        vim.setCursor(line: 7, column: 0)
        vim.feed("zcggOnew<Esc>")
        #expect(hiddenLines(vim) == [[9, 10]], "a line added above moves the fold")
        vim.feed("9GA!<Esc>")
        #expect(hiddenLines(vim) == [[9, 10]], "typing on the header keeps it")
        vim.replaceCharacters(in: NSRange(location: (vim.text as NSString).range(of: "three").location, length: 0), with: "X")
        #expect(hiddenLines(vim) == [[9, 10]], "an edit inside the fold keeps it")
        vim.feed("9Gdd")
        #expect(!vim.text.contains("func b") && !vim.text.contains("three"), "dd on the header deletes the whole fold")
        #expect(vim.folds.isEmpty)
    }

    @Test func linewiseOperatorsTakeTheWholeFold() {
        let vim = engine()
        vim.feed("zcyyGp")
        #expect(vim.text.hasSuffix("}\nfunc a() {\n  if x {\n    one\n  }\n  two\n}"), "yy yanks the fold")
        vim.feed("gg>>")
        #expect(vim.text.hasPrefix("    func a() {\n      if x {\n        one"), ">> indents every line")
        #expect(hiddenLines(vim).first == [1, 5], "and the fold stays closed")
        vim.feed("2dd")
        #expect(vim.text.hasPrefix("func b() {"), "2dd: the fold and the next line")
        vim.feed("u")
        vim.feed(":%s/one/ONE/<CR>")
        #expect(vim.text.contains("ONE"))
        #expect(vim.folds.isEmpty, ":s moves the cursor into the fold, which opens it")
    }

    @Test func setTextClearsFolds() {
        let vim = engine()
        vim.feed("zM")
        vim.setText("other")
        #expect(vim.folds.isEmpty)
    }
}

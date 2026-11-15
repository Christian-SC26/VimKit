#if os(macOS)
import AppKit
import Testing
@testable import VimCore
@testable import VimKit

/// What NSTextView gave for free: ⌘E, Services, dragging text, Look Up.
@MainActor
@Suite(.serialized)
struct TextViewServicesTests {
    @Test func commandEUsesTheWordUnderTheCursor() {
        let editor = EditorWindow(text: "let value = compute(value)")
        let view = editor.view
        editor.type("w")
        #expect(view.selectedRange().length == 0, "normal mode selects nothing")
        #expect(view.wordUnderCursor == NSRange(location: 4, length: 5))
        let usable = view.withFindSelection(for: .setSearchString) { () -> (Bool, NSRange?) in
            (view.textFinder.validateAction(.setSearchString), view.textFinderClient?.firstSelectedRange)
        }
        #expect(usable.0, "⌘E is enabled with nothing selected")
        #expect(usable.1 == NSRange(location: 4, length: 5), "the finder sees the word as the selection")
        #expect(view.textFinderClient?.firstSelectedRange.length == 0, "only during the action")
        editor.type("e")
        editor.type("l")
        #expect(view.wordUnderCursor == NSRange(location: 9, length: 1) || view.wordUnderCursor == nil, "blanks are not a word")
    }

    @Test func servicesSendTheSelectionAndReplaceIt() throws {
        let editor = EditorWindow(text: "one two three")
        let view = editor.view
        #expect(view.validRequestor(forSendType: .string, returnType: .string) as? VimTextView == nil, "nothing selected")
        editor.type("wviw")
        #expect(view.selectedRange() == NSRange(location: 4, length: 3))
        #expect(view.validRequestor(forSendType: .string, returnType: .string) as? VimTextView === view)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "two")
        pasteboard.clearContents()
        pasteboard.setString("TWO", forType: .string)
        #expect(view.readSelection(from: pasteboard))
        #expect(view.string == "one TWO three")
        #expect(view.string == view.vim.text)
    }

    @Test func droppedTextIsInsertedOrMoved() {
        let editor = EditorWindow(text: "alpha beta gamma")
        let view = editor.view
        var changes = 0
        view.onTextChange = { changes += 1 }
        #expect(view.drop("X ", at: 6, moving: nil))
        #expect(view.string == "alpha X beta gamma")
        #expect(view.selectedRange() == NSRange(location: 6, length: 2))
        // Moving "beta " to the start.
        #expect(view.drop("beta ", at: 0, moving: NSRange(location: 8, length: 5)))
        #expect(view.string == "beta alpha X gamma")
        // Moving it forward past itself.
        #expect(view.drop("beta ", at: 13, moving: NSRange(location: 0, length: 5)))
        #expect(view.string == "alpha X beta gamma")
        #expect(!view.drop("beta ", at: 9, moving: NSRange(location: 8, length: 5)), "onto itself")
        #expect(view.string == view.vim.text)
        #expect(changes == 3)
        editor.type("<Esc>u")
        #expect(view.string == view.vim.text)
    }

    @Test func lookUpPicksTheWordOrSelection() {
        let editor = EditorWindow(text: "hello wonderful world  ()")
        let view = editor.view
        #expect(view.lookUpRange(at: 8) == NSRange(location: 6, length: 9))
        #expect(view.lookUpRange(at: 22) == nil, "no letters")
        view.setSelectedRange(NSRange(location: 6, length: 15))
        #expect(view.lookUpRange(at: 8) == NSRange(location: 6, length: 15))
    }

    @Test func rightToLeftTextHasBoxesAndSelections() throws {
        let editor = EditorWindow(text: "let s = \"שלום עולם\" // مرحبا")
        let view = editor.view
        let text = view.string as NSString
        let hebrew = text.range(of: "שלום")
        var xs: [CGFloat] = []
        for offset in hebrew.location..<hebrew.upperBound {
            let rect = try #require(view.characterRect(at: offset))
            #expect(rect.width > 1)
            #expect(view.characterIndex(at: CGPoint(x: rect.midX, y: rect.midY)) == offset)
            xs.append(rect.minX)
        }
        #expect(xs == xs.sorted(by: >), "Hebrew runs right to left: \(xs)")
        #expect(view.rowRects(for: hebrew).allSatisfy { $0.width > 20 })
    }
}
#endif

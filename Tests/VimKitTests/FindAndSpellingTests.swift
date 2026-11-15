#if os(macOS)
import AppKit
import Testing
@testable import VimCore
@testable import VimKit

/// The system find bar (NSTextFinder) and spell checking on VimTextView.
/// The find pasteboard is shared with other apps, so searches are not typed
/// into the bar: the tests drive the NSTextFinderClient side directly.
@MainActor
@Suite(.serialized)
struct FindAndSpellingTests {
    @Test func commandFOpensTheFindBar() throws {
        let editor = EditorWindow(text: WindowScenarioTests.numbered(100))
        #expect(!editor.scrollView.isFindBarVisible)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
                                                  isARepeat: false, keyCode: 3))
        #expect(editor.view.performKeyEquivalent(with: event))
        #expect(editor.scrollView.isFindBarVisible)
        #expect(editor.view.string == editor.view.vim.text, "⌘F is not a Vim key")
        // The bar insets the clip view; the text moves down under it.
        let clip = editor.scrollView.contentView
        let inset = clip.contentInsets.top
        #expect(inset > 0)
        let firstLine = try #require(editor.view.characterRect(at: 0))
        #expect(firstLine.minY >= clip.bounds.minY + inset, "first line is below the find bar")
        // Screen motions measure the text below the bar.
        editor.type("50Gzt")
        let line49 = try #require(editor.view.characterRect(at: editor.view.vim.cursorOffset))
        #expect(abs(line49.minY - (clip.bounds.minY + inset)) < 1, "zt puts the line right under the bar")
        editor.type("gg")
        editor.view.textFinder.performAction(.hideFindInterface)
        #expect(!editor.scrollView.isFindBarVisible)
        #expect(clip.contentInsets.top == 0 && clip.bounds.minY == 0, "insets \(clip.contentInsets.top), origin \(clip.bounds.minY)")
    }

    @Test func finderSeesTheTextAndItsGeometry() throws {
        let editor = EditorWindow(text: WindowScenarioTests.numbered(2_000))
        let view = editor.view
        _ = view.textFinder
        let client = try #require(view.textFinderClient)
        #expect(client.string == view.string)
        let target = (view.string as NSString).range(of: "line 1500")
        client.selectedRanges = [NSValue(range: target)]
        client.scrollRangeToVisible(target)
        #expect(view.selectedRange() == target)
        let rects = try #require(client.rects(forCharacterRange: target)).map(\.rectValue)
        #expect(rects.count == 1)
        let first = try #require(view.characterRect(at: target.location))
        #expect(abs(rects[0].minX - first.minX) < 0.5 && rects[0].minY == first.minY)
        #expect(editor.visibleRect.contains(CGPoint(x: rects[0].minX + 1, y: rects[0].midY)), "match scrolled into view")
        let visible = try #require(client.visibleCharacterRanges.first).rangeValue
        #expect(NSLocationInRange(target.location, visible))
        var range = NSRange()
        #expect(client.contentView(at: target.location, effectiveCharacterRange: &range) === view)
        #expect(range == NSRange(location: 0, length: (view.string as NSString).length))
    }

    @Test func replaceAllReachesTheEngineOnce() throws {
        let editor = EditorWindow(text: WindowScenarioTests.numbered(3_000))
        let view = editor.view
        _ = view.textFinder
        let client = try #require(view.textFinderClient)
        var changes = 0
        view.onTextChange = { changes += 1 }
        let text = view.string as NSString
        var matches: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while case let found = text.range(of: "line", range: search), found.location != NSNotFound {
            matches.append(found)
            search = NSRange(location: found.upperBound, length: text.length - found.upperBound)
        }
        let start = ContinuousClock.now
        #expect(client.shouldReplaceCharacters(inRanges: matches.map { NSValue(range: $0) }, with: matches.map { _ in "row" }))
        for match in matches.reversed() { client.replaceCharacters(in: match, with: "row") }
        client.didReplaceCharacters()
        let elapsed = ContinuousClock.now - start
        #expect(view.string == WindowScenarioTests.numbered(3_000).replacingOccurrences(of: "line", with: "row"))
        #expect(view.string == view.vim.text)
        #expect(changes == 1, "the app hears about Replace All once")
        #expect(elapsed < .seconds(5), "Replace All of 3000 matches took \(elapsed)")
        editor.type("u")
        #expect(view.string == view.vim.text)
    }

    /// Waits for the background spell check of the visible lines.
    func checkedMisspellings(_ view: VimTextView, line: Int) -> [NSRange]? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let ranges = view.misspellings(inLine: line) { return ranges }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    @Test func misspelledWordsAreFoundAndGuessed() throws {
        let editor = EditorWindow(text: "Thiss is a tesst of spelling\nlet x = 1")
        let view = editor.view
        view.isContinuousSpellCheckingEnabled = true
        let text = view.string as NSString
        let ranges = try #require(checkedMisspellings(view, line: 0))
        #expect(ranges.contains(text.range(of: "Thiss")))
        #expect(ranges.contains(text.range(of: "tesst")))
        #expect(!ranges.contains(text.range(of: "spelling")))
        let word = try #require(view.characterRect(at: text.range(of: "tesst").location + 1))
        let menu = try #require(view.menu(for: NSEvent.mouseEvent(
            with: .rightMouseDown, location: view.convert(CGPoint(x: word.midX, y: word.midY), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!))
        #expect(menu.items.contains { $0.title == "test" }, "guesses: \(menu.items.map(\.title))")
        let fix = try #require(menu.items.first { $0.title == "test" })
        _ = (fix.target as? NSObject)?.perform(fix.action, with: fix)
        #expect(view.string.hasPrefix("Thiss is a test of"))
        #expect(view.string == view.vim.text)
    }

    @Test func spellingCanBeLimitedToStringsAndComments() throws {
        let editor = EditorWindow(text: "lett x = 1 // a commentt")
        let view = editor.view
        view.isContinuousSpellCheckingEnabled = true
        view.spellCheckingScope = .stringsAndComments
        let text = view.string as NSString
        view.textStorage.addAttribute(.vimTokenType, value: VimTokenType.comment, range: text.range(of: "// a commentt"))
        let ranges = try #require(checkedMisspellings(view, line: 0))
        #expect(ranges == [text.range(of: "commentt")])
    }
}
#endif

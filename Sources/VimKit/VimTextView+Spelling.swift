#if os(macOS)
import AppKit
import CoreText

/// Which text continuous spell checking looks at.
public enum VimSpellCheckingScope: Sendable {
    /// All of the text.
    case all
    /// Only strings and comments, as marked by the `.vimTokenType`
    /// attribute or ``VimTextView/tokenTypeProvider``. Code stays unmarked.
    case stringsAndComments
}

/// Spell checking for ``VimTextView`` with `NSSpellChecker`: misspelled words
/// in visible lines are underlined (checked in the background, line by line,
/// and remembered by the line's text), the context menu offers guesses, and
/// Edit › Spelling and Grammar works (⌘; and the Spelling panel).
extension VimTextView {
    /// Misspelled ranges in `line` (document offsets), or nil while the line
    /// is being checked.
    func misspellings(inLine line: Int) -> [NSRange]? {
        let start = layout.starts[line], length = layout.lineEnd(line) - start
        guard length > 0 else { return [] }
        let text = textStorage.mutableString.substring(with: NSRange(location: start, length: length))
        guard let ranges = spellResults[text] else {
            requestSpelling(of: text)
            return nil
        }
        return ranges.compactMap { range in
            let range = NSRange(location: start + range.location, length: range.length)
            return isInSpellingScope(range) ? range : nil
        }
    }

    private func isInSpellingScope(_ range: NSRange) -> Bool {
        switch spellCheckingScope {
        case .all: return true
        case .stringsAndComments:
            if let tokenTypeProvider { return tokenTypeProvider(range.location + 1) != nil }
            return VimTokenType.at(range.location, in: textStorage) != nil
        }
    }

    private func requestSpelling(of text: String) {
        guard !spellPending.contains(text) else { return }
        spellPending.insert(text)
        NSSpellChecker.shared.requestChecking(
            of: text, range: NSRange(location: 0, length: (text as NSString).length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil,
            inSpellDocumentWithTag: spellDocumentTag
        ) { @Sendable [weak self] _, results, _, _ in
            let ranges = results.filter { $0.resultType == .spelling }.map(\.range)
            // The run loop, not the main queue: results also arrive while the
            // main thread runs a nested loop (scroll tracking, modal panels).
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.spellPending.remove(text)
                    if self.spellResults.count > 4_000 { self.spellResults = [:] }
                    self.spellResults[text] = ranges
                    if self.isContinuousSpellCheckingEnabled { self.needsDisplay = true }
                }
            }
        }
    }

    /// Red dots under the misspelled words of `lines`.
    func drawMisspellings(lines: [(line: Int, y: CGFloat)]) {
        let origin = textOrigin
        let path = NSBezierPath()
        for (line, y) in lines {
            for range in misspellings(inLine: line) ?? [] {
                forEachRow(of: range, lines: [(line, y)]) { start, rowStart, rowEnd, ctLine, top, _ in
                    let (minX, maxX) = rowSpan(ctLine, from: max(range.location, rowStart) - start, to: min(range.upperBound, rowEnd) - start)
                    let baseline = top + min(layout.baseline + 3, lineHeight - 1)
                    path.move(to: CGPoint(x: origin.x + minX + 1, y: baseline))
                    path.line(to: CGPoint(x: origin.x + maxX - 1, y: baseline))
                }
            }
        }
        guard !path.isEmpty else { return }
        NSColor.systemRed.setStroke()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.setLineDash([0, 3], count: 2, phase: 0)
        path.stroke()
    }

    /// The misspelled word at `offset`, if continuous checking marked one.
    func misspelledRange(at offset: Int) -> NSRange? {
        guard isContinuousSpellCheckingEnabled, textStorage.length > 0 else { return nil }
        let offset = min(offset, textStorage.length - 1)
        return misspellings(inLine: layout.line(containing: offset))?.first { NSLocationInRange(offset, $0) }
    }

    /// Guesses, Ignore and Learn for a misspelled word under `point`.
    func addSpellingSuggestions(to menu: NSMenu, at point: CGPoint) {
        guard let range = misspelledRange(at: characterIndex(at: point)) else { return }
        let word = textStorage.attributedSubstring(from: range).string
        let guesses = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                                    in: word, language: nil, inSpellDocumentWithTag: spellDocumentTag) ?? []
        if guesses.isEmpty {
            let item = menu.addItem(withTitle: "No Guesses Found", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for guess in guesses.prefix(8) {
            let item = menu.addItem(withTitle: guess, action: #selector(replaceWithGuess(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingFix(range: range, word: word, replacement: guess)
        }
        menu.addItem(.separator())
        for (title, action) in [("Ignore Spelling", #selector(ignoreSpellingFromMenu(_:))), ("Learn Spelling", #selector(learnSpellingFromMenu(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingFix(range: range, word: word, replacement: word)
        }
        menu.addItem(.separator())
    }

    @objc private func replaceWithGuess(_ item: NSMenuItem) {
        guard let fix = item.representedObject as? SpellingFix, fix.range.upperBound <= textStorage.length,
              textStorage.attributedSubstring(from: fix.range).string == fix.word else { return }
        replace(fix.range, with: fix.replacement)
    }

    @objc private func ignoreSpellingFromMenu(_ item: NSMenuItem) {
        guard let fix = item.representedObject as? SpellingFix else { return }
        NSSpellChecker.shared.ignoreWord(fix.word, inSpellDocumentWithTag: spellDocumentTag)
        spellingDidChange()
    }

    @objc private func learnSpellingFromMenu(_ item: NSMenuItem) {
        guard let fix = item.representedObject as? SpellingFix else { return }
        NSSpellChecker.shared.learnWord(fix.word)
        spellingDidChange()
    }

    private func spellingDidChange() {
        spellResults = [:]
        needsDisplay = true
    }

    // MARK: Edit › Spelling and Grammar

    @objc public func toggleContinuousSpellChecking(_ sender: Any?) {
        isContinuousSpellCheckingEnabled.toggle()
    }

    /// Selects the next misspelled word after the selection (⌘;) and shows it
    /// in the Spelling panel.
    @objc public func checkSpelling(_ sender: Any?) {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: string, startingAt: selectedRange().upperBound, language: nil, wrap: true,
                                          inSpellDocumentWithTag: spellDocumentTag, wordCount: nil)
        guard range.location != NSNotFound, range.length > 0 else {
            checker.updateSpellingPanel(withMisspelledWord: "")
            return
        }
        setSelectedRange(range)
        scrollTextToVisible(layoutRect(at: range.location).insetBy(dx: 0, dy: -lineHeight))
        checker.updateSpellingPanel(withMisspelledWord: textStorage.attributedSubstring(from: range).string)
    }

    /// Edit › Spelling and Grammar › Show Spelling and Grammar.
    @objc public func showGuessPanel(_ sender: Any?) {
        NSSpellChecker.shared.spellingPanel.orderFront(sender)
        checkSpelling(sender)
    }

    /// The Spelling panel's Change button: replaces the selection.
    @objc public func changeSpelling(_ sender: Any?) {
        guard let word = (sender as? NSControl)?.selectedCell()?.stringValue, selectedRange().length > 0 else { return }
        replace(selectedRange(), with: word)
    }

    /// The Spelling panel's Ignore button.
    @objc public func ignoreSpelling(_ sender: Any?) {
        guard let word = (sender as? NSControl)?.selectedCell()?.stringValue else { return }
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: spellDocumentTag)
        spellingDidChange()
    }
}

/// A context menu choice for a misspelled word.
private final class SpellingFix: NSObject {
    let range: NSRange
    let word: String
    let replacement: String

    init(range: NSRange, word: String, replacement: String) {
        self.range = range
        self.word = word
        self.replacement = replacement
    }
}
#endif

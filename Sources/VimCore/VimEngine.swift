import Foundation
import JavaScriptCore

/// Connects a ``VimEngine`` to a text view.
///
/// The engine owns the authoritative copy of the text. It calls the editing
/// methods to mirror its changes into the view, and the geometry methods to
/// implement screen-relative commands (`gj`, `H`, `zz`, `<C-d>`, ...).
/// Geometry methods may return `nil`; the engine then falls back to treating
/// every logical line as one screen line.
@MainActor
public protocol VimEngineDelegate: AnyObject {
    /// Mirror a text change made by vim. `range` is in the text before the change.
    ///
    /// Changes arrive in batches, one per vim command, between
    /// ``vimEngineWillApplyEdits(_:)`` and ``vimEngineDidApplyEdits(_:)``. A
    /// command that edits many places (`:%s`, undoing it) is sent as one
    /// replacement of the whole region that changed.
    func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String)
    func vimEngineWillApplyEdits(_ engine: VimEngine)
    func vimEngineDidApplyEdits(_ engine: VimEngine)
    func vimEngine(_ engine: VimEngine, setSelections selections: [VimSelection], primary: Int)
    func vimEngineDidChangeStatus(_ engine: VimEngine)
    /// `:w` or `:write`.
    func vimEngineDidRequestSave(_ engine: VimEngine)
    /// The search highlight changed; query ``VimEngine/searchMatches(in:limit:)``.
    func vimEngineSearchHighlightDidChange(_ engine: VimEngine)
    /// An ex command defined with ``VimEngine/defineEx(_:prefix:handler:)`` without a handler.
    func vimEngine(_ engine: VimEngine, didRun command: VimExCommand)
    func vimEngineDidRequestFocus(_ engine: VimEngine)

    /// Rectangle of the character at `offset`, in content coordinates.
    func vimEngine(_ engine: VimEngine, rectForCharacterAt offset: Int) -> CGRect?
    /// Offset of the character at `point`, in content coordinates.
    func vimEngine(_ engine: VimEngine, characterIndexAt point: CGPoint) -> Int?
    func vimEngineScrollInfo(_ engine: VimEngine) -> VimScrollInfo?
    /// Scroll so the visible rect starts at `x`/`y` (nil leaves an axis alone).
    func vimEngine(_ engine: VimEngine, scrollToX x: CGFloat?, y: CGFloat?)
    func vimEngine(_ engine: VimEngine, scrollCharacterToVisible offset: Int, margin: CGFloat)
    /// Offset one screen line (or page) up or down from `offset`, keeping `goalX` if given.
    func vimEngine(_ engine: VimEngine, verticalMoveFrom offset: Int, forward: Bool, byPage: Bool, goalX: CGFloat?) -> Int?
    /// Start or end of the screen line (wrapped line fragment) containing `offset`.
    func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int?
    func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat?
    /// Whether the character just before `offset` is inside a string or comment.
    /// Return nil when the host has no syntax information.
    func vimEngine(_ engine: VimEngine, tokenTypeAt offset: Int) -> VimTokenType?
}

public extension VimEngineDelegate {
    func vimEngine(_ engine: VimEngine, replaceCharactersIn range: NSRange, with text: String) {}
    func vimEngineWillApplyEdits(_ engine: VimEngine) {}
    func vimEngineDidApplyEdits(_ engine: VimEngine) {}
    func vimEngine(_ engine: VimEngine, setSelections selections: [VimSelection], primary: Int) {}
    func vimEngineDidChangeStatus(_ engine: VimEngine) {}
    func vimEngineDidRequestSave(_ engine: VimEngine) {}
    func vimEngineSearchHighlightDidChange(_ engine: VimEngine) {}
    func vimEngine(_ engine: VimEngine, didRun command: VimExCommand) {}
    func vimEngineDidRequestFocus(_ engine: VimEngine) {}
    func vimEngine(_ engine: VimEngine, rectForCharacterAt offset: Int) -> CGRect? { nil }
    func vimEngine(_ engine: VimEngine, characterIndexAt point: CGPoint) -> Int? { nil }
    func vimEngineScrollInfo(_ engine: VimEngine) -> VimScrollInfo? { nil }
    func vimEngine(_ engine: VimEngine, scrollToX x: CGFloat?, y: CGFloat?) {}
    func vimEngine(_ engine: VimEngine, scrollCharacterToVisible offset: Int, margin: CGFloat) {}
    func vimEngine(_ engine: VimEngine, verticalMoveFrom offset: Int, forward: Bool, byPage: Bool, goalX: CGFloat?) -> Int? { nil }
    func vimEngine(_ engine: VimEngine, screenLineBoundaryFrom offset: Int, forward: Bool) -> Int? { nil }
    func vimEngineLineHeight(_ engine: VimEngine) -> CGFloat? { nil }
    func vimEngine(_ engine: VimEngine, tokenTypeAt offset: Int) -> VimTokenType? { nil }
}

/// One Vim-enabled document.
///
/// Feed it key presses with ``handle(_:)``; it edits its text and reports the
/// changes to its ``delegate``. When the hosting view changes the text or the
/// selection on its own (typing in insert mode, paste, mouse), tell the engine
/// with ``replaceCharacters(in:with:)`` and ``setSelections(_:primary:)``.
///
/// All offsets are UTF-16 code units, the same as `NSString` and `NSRange`.
@MainActor
public final class VimEngine {
    public weak var delegate: (any VimEngineDelegate)?
    public let runtime: VimRuntime
    public private(set) var status = VimStatus()

    /// Called after ``status`` changes, in addition to the delegate.
    public var onStatusChange: ((VimStatus) -> Void)?

    private var editor: JSValue!
    private var exHandlers: [String: (VimExCommand) -> Void] = [:]

    public init(text: String = "", options: VimOptions = VimOptions(), runtime: VimRuntime? = nil) {
        self.runtime = runtime ?? .shared
        let host = makeHost()
        editor = self.runtime.api.invokeMethod(
            "createEditor", withArguments: [host, text, options.jsObject]
        )
    }

    isolated deinit {
        editor?.invokeMethod("destroy", withArguments: [])
    }

    // MARK: Input

    /// Handles a key press. Returns false when the key should go to the text
    /// view instead (typing text in insert mode, Command shortcuts).
    @discardableResult
    public func handle(_ event: VimKeyEvent) -> Bool {
        editor.invokeMethod("handleKeyEvent", withArguments: [event.jsObject])?.toBool() ?? false
    }

    /// Plays keys written in Vim notation, e.g. `ciwhello<Esc>` or
    /// `:%s/a/b/g<CR>`. Keys vim does not consume are typed as text.
    public func feed(_ keys: String) {
        editor.invokeMethod("feedKeys", withArguments: [keys])
    }

    /// Runs an ex command against this document, e.g. `%s/foo/bar/g`.
    public func execute(_ command: String) {
        editor.invokeMethod("exec", withArguments: [VimRuntime.stripColon(command)])
    }

    // MARK: Text and selection

    public var text: String {
        editor.invokeMethod("getValue", withArguments: [])?.toString() ?? ""
    }

    /// Replaces the whole text without notifying the delegate (the caller is
    /// expected to have set the same text in its view). Clears undo history.
    public func setText(_ text: String) {
        editor.invokeMethod("hostSetValue", withArguments: [text])
    }

    /// Tells the engine the view changed text on its own. `range` is in the
    /// text before the change.
    public func replaceCharacters(in range: NSRange, with text: String) {
        editor.invokeMethod(
            "hostReplace", withArguments: [range.location, range.location + range.length, text]
        )
    }

    /// Tells the engine the view changed the selection on its own (mouse, arrow keys in insert mode).
    public func setSelections(_ selections: [VimSelection], primary: Int = 0) {
        guard !selections.isEmpty else { return }
        let flat = selections.flatMap { [$0.anchor, $0.head] }
        editor.invokeMethod("hostSelect", withArguments: [flat, primary])
    }

    public var selections: [VimSelection] {
        let flat = (editor.invokeMethod("selectionOffsets", withArguments: [])?.toArray() as? [NSNumber]) ?? []
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            VimSelection(anchor: flat[$0].intValue, head: flat[$0 + 1].intValue)
        }
    }

    /// Offset of the primary selection's head.
    public var cursorOffset: Int {
        Int(editor.invokeMethod("cursorOffset", withArguments: [])?.toInt32() ?? 0)
    }

    /// Line and column of the primary selection's head.
    public var cursor: VimPosition {
        let pos = editor.invokeMethod("getCursor", withArguments: [])
        return VimPosition(
            line: Int(pos?.objectForKeyedSubscript("line")?.toInt32() ?? 0),
            column: Int(pos?.objectForKeyedSubscript("ch")?.toInt32() ?? 0)
        )
    }

    public func setCursor(line: Int, column: Int) {
        editor.invokeMethod("setCursor", withArguments: [line, column])
    }

    public var mode: VimMode { status.mode }

    // MARK: History

    public func undo() { editor.invokeMethod("undo", withArguments: []) }
    public func redo() { editor.invokeMethod("redo", withArguments: []) }

    // MARK: Search highlight

    /// Ranges matching the active search (`/`, `*`, `n`) inside `range`
    /// (whole document when nil). Empty when nothing is highlighted.
    public func searchMatches(in range: NSRange? = nil, limit: Int = 10_000) -> [NSRange] {
        let from = range?.location ?? 0
        let to = range.map { $0.location + $0.length } ?? -1
        let flat = (editor.invokeMethod("matchRanges", withArguments: [from, to, limit])?.toArray() as? [NSNumber]) ?? []
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            NSRange(location: flat[$0].intValue, length: flat[$0 + 1].intValue - flat[$0].intValue)
        }
    }

    // MARK: Options and commands

    /// Sets an editor option: `tabSize`, `indentUnit`, `indentWithTabs`,
    /// `readOnly`, `lineComment`, `textwidth`.
    public func setOption(_ name: String, _ value: Any) {
        editor.invokeMethod("setOption", withArguments: [name, value])
    }

    /// Defines an ex command, e.g. `defineEx("quit", prefix: "q") { _ in close() }`.
    /// Ex commands are global in vim; each engine keeps its own handler, and
    /// the delegate gets commands this engine has no handler for.
    public func defineEx(_ name: String, prefix: String? = nil, handler: ((VimExCommand) -> Void)? = nil) {
        runtime.defineExIfNeeded(name, prefix: prefix)
        exHandlers[name] = handler
    }

    // MARK: Host bridge

    private func makeHost() -> JSValue {
        let host = JSValue(newObjectIn: runtime.context)!
        func install(_ name: String, _ block: Any) {
            host.setObject(block, forKeyedSubscript: name as NSString)
        }

        // [from, to, text, from, to, text, ...]; each edit refers to the text after the previous one.
        let edits: @convention(block) (JSValue) -> Void = { [weak self] list in
            guard let self, let delegate = self.delegate else { return }
            let length = Int(list.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            guard length >= 3 else { return }
            delegate.vimEngineWillApplyEdits(self)
            for index in stride(from: 0, to: length - 2, by: 3) {
                let from = Int(list.atIndex(index).toInt32())
                let to = Int(list.atIndex(index + 1).toInt32())
                let text = list.atIndex(index + 2).toString() ?? ""
                delegate.vimEngine(self, replaceCharactersIn: NSRange(location: from, length: to - from), with: text)
            }
            delegate.vimEngineDidApplyEdits(self)
        }
        let select: @convention(block) (JSValue, Double) -> Void = { [weak self] flatValue, primary in
            guard let self else { return }
            let flat = (flatValue.toArray() as? [NSNumber]) ?? []
            let selections = stride(from: 0, to: flat.count - 1, by: 2).map {
                VimSelection(anchor: flat[$0].intValue, head: flat[$0 + 1].intValue)
            }
            self.delegate?.vimEngine(self, setSelections: selections, primary: Int(primary))
        }
        let state: @convention(block) (String) -> Void = { [weak self] json in
            self?.updateStatus(json)
        }
        let event: @convention(block) (String, String) -> Void = { [weak self] name, _ in
            guard let self else { return }
            switch name {
            case "save": self.delegate?.vimEngineDidRequestSave(self)
            case "highlight": self.delegate?.vimEngineSearchHighlightDidChange(self)
            case "focus": self.delegate?.vimEngineDidRequestFocus(self)
            default: break
            }
        }
        let ex: @convention(block) (String) -> Void = { [weak self] json in
            guard let self,
                  let command = try? JSONDecoder().decode(VimExCommand.self, from: Data(json.utf8))
            else { return }
            if let handler = self.exHandlers[command.name] {
                handler(command)
            } else {
                self.delegate?.vimEngine(self, didRun: command)
            }
        }
        let coords: @convention(block) (Double) -> NSArray = { [weak self] offset in
            guard let self, let rect = self.delegate?.vimEngine(self, rectForCharacterAt: Int(offset)) else { return [] }
            return [rect.minX, rect.minY, rect.maxY] as NSArray
        }
        let offsetAt: @convention(block) (Double, Double) -> Double = { [weak self] x, y in
            guard let self, let index = self.delegate?.vimEngine(self, characterIndexAt: CGPoint(x: x, y: y)) else { return -1 }
            return Double(index)
        }
        let scrollInfo: @convention(block) () -> NSArray = { [weak self] in
            guard let self, let info = self.delegate?.vimEngineScrollInfo(self) else { return [] }
            let v = info.visibleRect
            return [v.minX, v.minY, info.contentSize.width, info.contentSize.height, v.width, v.height] as NSArray
        }
        let scrollTo: @convention(block) (Double, Double) -> Void = { [weak self] x, y in
            guard let self else { return }
            self.delegate?.vimEngine(self, scrollToX: x.isNaN ? nil : x, y: y.isNaN ? nil : y)
        }
        let scrollIntoView: @convention(block) (Double, Double) -> Void = { [weak self] offset, margin in
            guard let self else { return }
            self.delegate?.vimEngine(self, scrollCharacterToVisible: Int(offset), margin: margin)
        }
        let moveVertically: @convention(block) (Double, Bool, Bool, Double) -> Double = { [weak self] offset, forward, page, goal in
            guard let self,
                  let target = self.delegate?.vimEngine(
                      self, verticalMoveFrom: Int(offset), forward: forward, byPage: page,
                      goalX: goal < 0 ? nil : goal
                  )
            else { return -1 }
            return Double(target)
        }
        let lineBoundary: @convention(block) (Double, Bool) -> Double = { [weak self] offset, forward in
            guard let self,
                  let target = self.delegate?.vimEngine(self, screenLineBoundaryFrom: Int(offset), forward: forward)
            else { return -1 }
            return Double(target)
        }
        let lineHeight: @convention(block) () -> Double = { [weak self] in
            guard let self else { return 0 }
            return self.delegate?.vimEngineLineHeight(self).map(Double.init) ?? 0
        }

        let tokenType: @convention(block) (Double) -> String = { [weak self] offset in
            guard let self else { return "" }
            return self.delegate?.vimEngine(self, tokenTypeAt: Int(offset))?.rawValue ?? ""
        }

        install("tokenType", unsafeBitCast(tokenType, to: AnyObject.self))
        install("edits", unsafeBitCast(edits, to: AnyObject.self))
        install("select", unsafeBitCast(select, to: AnyObject.self))
        install("state", unsafeBitCast(state, to: AnyObject.self))
        install("event", unsafeBitCast(event, to: AnyObject.self))
        install("ex", unsafeBitCast(ex, to: AnyObject.self))
        install("coords", unsafeBitCast(coords, to: AnyObject.self))
        install("offsetAt", unsafeBitCast(offsetAt, to: AnyObject.self))
        install("scrollInfo", unsafeBitCast(scrollInfo, to: AnyObject.self))
        install("scrollTo", unsafeBitCast(scrollTo, to: AnyObject.self))
        install("scrollIntoView", unsafeBitCast(scrollIntoView, to: AnyObject.self))
        install("moveVertically", unsafeBitCast(moveVertically, to: AnyObject.self))
        install("lineBoundary", unsafeBitCast(lineBoundary, to: AnyObject.self))
        install("lineHeight", unsafeBitCast(lineHeight, to: AnyObject.self))
        return host
    }

    private struct RawStatus: Decodable {
        var mode: String
        var subMode: String
        var pending: String
        var insertModeReturn: Bool
        var cursor: Int
        var commandLine: VimCommandLine?
        var banner: String?
        var message: String?
        var messageIsError: Bool
    }

    private func updateStatus(_ json: String) {
        guard let raw = try? JSONDecoder().decode(RawStatus.self, from: Data(json.utf8)) else { return }
        var new = VimStatus()
        switch (raw.mode, raw.subMode) {
        case ("insert", _): new.mode = .insert
        case ("replace", _): new.mode = .replace
        case ("visual", "linewise"): new.mode = .visualLine
        case ("visual", "blockwise"): new.mode = .visualBlock
        case ("visual", _): new.mode = .visual
        default: new.mode = .normal
        }
        new.pendingKeys = raw.pending
        new.isInsertModeReturn = raw.insertModeReturn
        new.cursorOffset = raw.cursor
        new.commandLine = raw.commandLine
        new.banner = raw.banner
        new.message = raw.message
        new.messageIsError = raw.messageIsError
        guard new != status else { return }
        status = new
        delegate?.vimEngineDidChangeStatus(self)
        onStatusChange?(new)
    }
}

import Foundation
import JavaScriptCore

/// The shared JavaScriptCore context that runs the vim engine.
///
/// Like Vim itself, every editor created in one runtime shares registers,
/// marks history, mappings, options and ex-command history. Create a separate
/// runtime only when you need fully isolated state (tests, for example).
@MainActor
public final class VimRuntime {
    public static let shared = VimRuntime()

    /// Storage for the `+` and `*` registers.
    public var clipboard: any VimClipboard = SystemClipboard()

    /// Implementation that finds indentation blocks for folds (`zM`, `zc`,
    /// ``VimEngine/foldBlocks()``). The results are identical; Swift is the
    /// fastest (VimKitBench runs 8–9: 0.62 ms on 20,000 lines, JavaScript 13 ms).
    public var foldKernel: VimFoldKernel = .swift

    /// Buffers of the native fold kernel, shared by this runtime's editors.
    @_spi(Benchmarks) public let foldScanner = VimFoldBlockScanner()

    /// Receives console output and JavaScript exceptions from the engine.
    /// By default warnings and errors are printed.
    public var log: (VimLogLevel, String) -> Void = { level, message in
        if level >= .warning { print("[VimKit] \(message)") }
    }

    let context: JSContext
    private(set) var api: JSValue!
    private var vim: JSValue { api.objectForKeyedSubscript("Vim") }
    private var timers: [Int: Task<Void, Never>] = [:]
    private var definedEx: Set<String> = []

    public init() {
        guard let context = JSContext() else {
            fatalError("VimKit: cannot create a JavaScriptCore context")
        }
        self.context = context
        context.name = "VimKit"
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.log(.error, "JavaScript exception: \(message)\n\(stack)")
        }
        installRuntimeObject()
        loadScripts()
    }

    // MARK: Global Vim configuration

    /// Runs an ex command that does not need a document, e.g.
    /// `set ignorecase`, `nnoremap Y y$` or `imap jk <Esc>`.
    public func execute(_ command: String) {
        api.invokeMethod("exec", withArguments: [Self.stripColon(command)])
    }

    /// Adds a recursive mapping, like `:map`. `mode` nil means all modes.
    public func map(_ lhs: String, to rhs: String, mode: VimMapMode? = nil) {
        vim.invokeMethod("map", withArguments: [lhs, rhs, mode?.rawValue as Any])
    }

    /// Adds a non-recursive mapping, like `:noremap`.
    public func noremap(_ lhs: String, to rhs: String, mode: VimMapMode? = nil) {
        vim.invokeMethod("noremap", withArguments: [lhs, rhs, mode?.rawValue as Any])
    }

    public func unmap(_ lhs: String, mode: VimMapMode? = nil) {
        vim.invokeMethod("unmap", withArguments: [lhs, mode?.rawValue as Any])
    }

    /// Removes all user mappings.
    public func removeAllMappings() {
        vim.invokeMethod("mapclear", withArguments: [])
    }

    /// Sets a global Vim option, e.g. `setOption("ignorecase", true)`.
    public func setOption(_ name: String, _ value: Any) {
        vim.invokeMethod("setOption", withArguments: [name, value])
    }

    public func option(_ name: String) -> Any? {
        vim.invokeMethod("getOption", withArguments: [name])?.toObject()
    }

    /// Sets Vim's `langmap`, mapping characters of another layout onto
    /// command keys, e.g. `"йq,цw,уe"`.
    public func setLangmap(_ langmap: String) {
        vim.invokeMethod("langmap", withArguments: [langmap])
    }

    /// Runs each line of a vimrc-style script (comments and blank lines are skipped).
    public func source(_ script: String) {
        for raw in script.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("\"") { continue }
            execute(line)
        }
    }

    /// Clears registers, history, marks and mappings.
    public func reset() {
        vim.invokeMethod("resetVimGlobalState_", withArguments: [])
        removeAllMappings()
    }

    // MARK: Internals

    func defineExIfNeeded(_ name: String, prefix: String?) {
        guard definedEx.insert(name).inserted else { return }
        api.invokeMethod("defineEx", withArguments: [name, prefix ?? name])
    }

    static func stripColon(_ command: String) -> String {
        var command = command.trimmingCharacters(in: .whitespaces)
        while command.hasPrefix(":") { command.removeFirst() }
        return command
    }

    private func installRuntimeObject() {
        let runtime = JSValue(newObjectIn: context)!

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log(VimLogLevel(jsLevel: level), message)
        }
        let setTimer: @convention(block) (Double, Double) -> Void = { [weak self] id, milliseconds in
            self?.scheduleTimer(Int(id), after: milliseconds)
        }
        let clearTimer: @convention(block) (Double) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: Int(id))?.cancel()
        }
        let clipboardRead: @convention(block) () -> String = { [weak self] in
            self?.clipboard.string ?? ""
        }
        let clipboardWrite: @convention(block) (String) -> Void = { [weak self] text in
            self?.clipboard.string = text
        }

        runtime.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        runtime.setObject(unsafeBitCast(setTimer, to: AnyObject.self), forKeyedSubscript: "setTimer" as NSString)
        runtime.setObject(unsafeBitCast(clearTimer, to: AnyObject.self), forKeyedSubscript: "clearTimer" as NSString)
        runtime.setObject(unsafeBitCast(clipboardRead, to: AnyObject.self), forKeyedSubscript: "clipboardRead" as NSString)
        runtime.setObject(unsafeBitCast(clipboardWrite, to: AnyObject.self), forKeyedSubscript: "clipboardWrite" as NSString)
        #if os(macOS)
        runtime.setObject("MacIntel", forKeyedSubscript: "platform" as NSString)
        #else
        runtime.setObject("iPhone", forKeyedSubscript: "platform" as NSString)
        #endif
        context.setObject(runtime, forKeyedSubscript: "__vimkitRuntime" as NSString)
    }

    private func loadScripts() {
        let bundle = Bundle.module
        guard
            let vimURL = bundle.url(forResource: "vim", withExtension: "js"),
            let adapterURL = bundle.url(forResource: "vimkit-adapter", withExtension: "js"),
            var vimSource = try? String(contentsOf: vimURL, encoding: .utf8),
            let adapterSource = try? String(contentsOf: adapterURL, encoding: .utf8)
        else {
            fatalError("VimKit: engine scripts are missing from the bundle")
        }
        // vim.js is an ES module with a single export; JavaScriptCore evaluates
        // plain scripts, so turn it into a global function declaration.
        vimSource = vimSource.replacingOccurrences(
            of: "export function initVim(", with: "function initVim("
        )
        context.evaluateScript(vimSource, withSourceURL: vimURL)
        context.evaluateScript(adapterSource, withSourceURL: adapterURL)
        api = context.objectForKeyedSubscript("VimKit")
        guard api?.isObject == true else {
            fatalError("VimKit: the engine failed to start")
        }
    }

    private func scheduleTimer(_ id: Int, after milliseconds: Double) {
        timers[id] = Task { [weak self] in
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            guard !Task.isCancelled, let self else { return }
            self.timers[id] = nil
            self.context.objectForKeyedSubscript("__vimkitFireTimer")?.call(withArguments: [id])
        }
    }

    /// Fires every pending timer now, in the order they were scheduled
    /// (tests use it instead of waiting for vim.js's timeouts).
    func firePendingTimers() {
        for id in timers.keys.sorted() {
            guard let task = timers.removeValue(forKey: id) else { continue }
            task.cancel()
            context.objectForKeyedSubscript("__vimkitFireTimer")?.call(withArguments: [id])
        }
    }
}

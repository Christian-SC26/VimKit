import Foundation
import JavaScriptCore
import VimGooseKernels

/// Which implementation finds the indentation blocks that `zM`, `zc` and
/// ``VimEngine/foldBlocks()`` use. All three give the same blocks; they
/// differ in speed (compare them with VimKitBench).
public enum VimFoldKernel: String, Sendable, CaseIterable {
    /// The adapter's JavaScript, on the document's lines.
    case javascript
    /// Swift, on the document's UTF-16 text.
    case swift
    /// Goose (Kernels/fold_blocks.goose) compiled to C, on the UTF-16 text.
    case goose
}

/// Finds indentation blocks in UTF-16 text with the Swift or the Goose
/// kernel. Keeps its buffers between calls.
@_spi(Benchmarks) public final class VimFoldBlockScanner {
    private var lastOf: [Int32] = []
    private var stackLine: [Int32] = []
    private var stackIndent: [Int32] = []

    public init() {}

    /// Blocks as flat `[header, last, header, last, ...]` line numbers, by header.
    public func blocks(in text: UnsafeBufferPointer<UInt16>, tabSize: Int, kernel: VimFoldKernel) -> [Int32] {
        let lines = scan(text, tabSize: tabSize, kernel: kernel)
        var flat: [Int32] = []
        for line in 0..<lines where lastOf[line] >= 0 {
            flat.append(Int32(line))
            flat.append(lastOf[line])
        }
        return flat
    }

    /// Runs the kernel only and returns the number of lines; for benchmarks.
    @discardableResult
    public func scan(_ text: UnsafeBufferPointer<UInt16>, tabSize: Int, kernel: VimFoldKernel) -> Int {
        var lines = 1
        for unit in text where unit == 0x0A { lines += 1 }
        if lastOf.count < lines {
            lastOf = Array(repeating: 0, count: lines)
            stackLine = lastOf
            stackIndent = lastOf
        }
        let tab = Int32(max(1, tabSize))
        return lastOf.withUnsafeMutableBufferPointer { lastOf in
            stackLine.withUnsafeMutableBufferPointer { stackLine in
                stackIndent.withUnsafeMutableBufferPointer { stackIndent in
                    switch kernel {
                    case .goose:
                        GooseRuntime.start()
                        func slice(_ buffer: UnsafeMutableBufferPointer<Int32>) -> sl_i32 {
                            sl_i32(data: buffer.baseAddress, len: Int64(buffer.count))
                        }
                        let input = sl_u16(data: UnsafeMutablePointer(mutating: text.baseAddress), len: Int64(text.count))
                        return Int(vimkit_fold_blocks(input, tab, slice(lastOf), slice(stackLine), slice(stackIndent)))
                    case .swift, .javascript:
                        return Self.scanSwift(text, tabSize: tab, lastOf: lastOf, stackLine: stackLine, stackIndent: stackIndent)
                    }
                }
            }
        }
    }

    /// The Swift kernel; the same algorithm as Kernels/fold_blocks.goose and
    /// `$allBlocksJS` in vimkit-adapter.js.
    static func scanSwift(_ text: UnsafeBufferPointer<UInt16>, tabSize: Int32, lastOf: UnsafeMutableBufferPointer<Int32>,
                          stackLine: UnsafeMutableBufferPointer<Int32>, stackIndent: UnsafeMutableBufferPointer<Int32>) -> Int {
        let n = text.count
        var depth = 0, prev: Int32 = -1, line: Int32 = 0, i = 0
        while true {
            var col: Int32 = 0, j = i, blank = true
            while j < n, text[j] != 0x0A {
                let c = text[j]
                if !isSpace(c) { blank = false; break }
                if c == 9 { col += tabSize - col % tabSize } else { col += 1 }
                j += 1
            }
            var e = j
            while e < n, text[e] != 0x0A { e += 1 }
            lastOf[Int(line)] = -1
            if !blank {
                var closing = -1
                while depth > 0, stackIndent[depth - 1] >= col {
                    depth -= 1
                    let header = stackLine[depth]
                    var last = prev
                    if stackIndent[depth] == col {
                        if closing < 0 { closing = isClosing(text, j, e) ? 1 : 0 }
                        if closing == 1 { last = line }
                    }
                    if last > header { lastOf[Int(header)] = last }
                }
                stackLine[depth] = line
                stackIndent[depth] = col
                depth += 1
                prev = line
            }
            line += 1
            if e >= n { break }
            i = e + 1
        }
        while depth > 0 {
            depth -= 1
            let header = stackLine[depth]
            if prev > header { lastOf[Int(header)] = prev }
        }
        return Int(line)
    }

    /// JavaScript's `\s`.
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool {
        if c == 32 || (c >= 9 && c <= 13) { return true }
        if c < 160 { return false }
        return c == 160 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029
            || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF
    }

    /// JavaScript's `\w`.
    @inline(__always) static func isWord(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    /// `]`, `)`, `}` or the word `end` at `j`, the line's first non-space character.
    @inline(__always) static func isClosing(_ text: UnsafeBufferPointer<UInt16>, _ j: Int, _ e: Int) -> Bool {
        let c = text[j]
        if c == 93 || c == 41 || c == 125 { return true }
        guard j + 3 <= e, text[j] == 101, text[j + 1] == 110, text[j + 2] == 100 else { return false }
        return j + 3 == e || !isWord(text[j + 3])
    }
}

/// The Goose runtime is set up once, on the first call.
enum GooseRuntime {
    private static let started: Void = goose_init(0, nil)
    static func start() { _ = started }
}

extension VimFoldBlockScanner {
    /// The adapter's `host.foldBlocks(text, tabSize)`: an `Int32Array` of
    /// `[header, last, ...]` from the native kernel, or null for JavaScript.
    /// The text is read in place as UTF-16 and the result is copied once.
    func hostBlocks(_ text: JSValue, tabSize: Int, kernel: VimFoldKernel, context: JSContext) -> JSValue {
        guard kernel != .javascript else { return JSValue(nullIn: context) }
        let ctx = context.jsGlobalContextRef
        guard let string = JSValueToStringCopy(ctx, text.jsValueRef, nil) else { return JSValue(nullIn: context) }
        defer { JSStringRelease(string) }
        let flat = blocks(in: UnsafeBufferPointer(start: JSStringGetCharactersPtr(string), count: JSStringGetLength(string)),
                          tabSize: tabSize, kernel: kernel)
        guard let array = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeInt32Array, flat.count, nil) else {
            return JSValue(nullIn: context)
        }
        if !flat.isEmpty, let bytes = JSObjectGetTypedArrayBytesPtr(ctx, array, nil) {
            flat.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        return JSValue(jsValueRef: array, in: context)
    }
}

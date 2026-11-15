import Foundation
import JavaScriptCore

/// New indentation for many lines at once (`>`, `<` and `=` over a range),
/// the adapter's `$indentPlanJS` in Swift. JavaScriptCore runs the adapter
/// without a JIT (always on iOS), so a scan over thousands of lines is
/// 10–20 times faster here.
enum VimIndentKernel {
    enum Mode: Int, CaseIterable { case less = 0, more = 1, auto = 2 }

    /// `[length of the leading spaces and tabs, new column, ...]` for each of
    /// `lines` (ascending line numbers). Column -1 leaves the line alone: a
    /// blank line under `=`, or a line number outside the text.
    static func plan(_ text: UnsafeBufferPointer<UInt16>, lines: UnsafeBufferPointer<Int32>, mode: Mode,
                     tabSize: Int32, unit: Int32) -> [Int32] {
        var starts = [0]
        starts.reserveCapacity(text.count / 32 + 1)
        for i in 0..<text.count where text[i] == 0x0A { starts.append(i + 1) }
        let lineCount = starts.count
        let tab = max(1, tabSize)
        func end(_ line: Int) -> Int { line + 1 < lineCount ? starts[line + 1] - 1 : text.count }
        /// Leading spaces and tabs: their length and the column after them.
        func leading(_ line: Int) -> (length: Int32, column: Int32) {
            var i = starts[line], column: Int32 = 0
            let e = end(line)
            while i < e {
                let c = text[i]
                if c == 32 { column += 1 } else if c == 9 { column += tab - column % tab } else { break }
                i += 1
            }
            return (Int32(i - starts[line]), column)
        }
        /// Only JavaScript `\s` characters.
        func isBlank(_ line: Int) -> Bool {
            var i = starts[line]
            let e = end(line)
            while i < e {
                if !VimFoldBlockScanner.isSpace(text[i]) { return false }
                i += 1
            }
            return true
        }

        var out = [Int32](repeating: -1, count: lines.count * 2)
        var reindented = mode == .auto ? [Int32](repeating: -1, count: lineCount) : []
        for (index, raw) in lines.enumerated() {
            let line = Int(raw)
            guard line >= 0, line < lineCount else { continue }
            let current = leading(line)
            out[2 * index] = current.length
            switch mode {
            case .more: out[2 * index + 1] = current.column + unit
            case .less: out[2 * index + 1] = max(0, current.column - unit)
            case .auto:
                if isBlank(line) { continue }
                var column: Int32 = 0
                var above = line - 1
                while above >= 0, isBlank(above) { above -= 1 }
                if above >= 0 {
                    column = reindented[above] >= 0 ? reindented[above] : leading(above).column
                    var depth = 0
                    for i in starts[above]..<end(above) {
                        switch text[i] {
                        case 40, 91, 123: depth += 1                        // ( [ {
                        case 41, 93, 125: if depth > 0 { depth -= 1 }       // ) ] }
                        default: break
                        }
                    }
                    if depth > 0 { column += unit }
                }
                let first = starts[line] + Int(current.length)
                if first < end(line), [41, 93, 125].contains(text[first]) { column = max(0, column - unit) }
                reindented[line] = column
                out[2 * index + 1] = column
            }
        }
        return out
    }

    /// The adapter's `host.indentPlan(text, lines, mode, tabSize, unit)`: an
    /// `Int32Array`, or null to let JavaScript do it.
    static func hostPlan(_ text: JSValue, _ lines: JSValue, mode: Int, tabSize: Int, unit: Int, context: JSContext) -> JSValue {
        let ctx = context.jsGlobalContextRef
        guard let mode = Mode(rawValue: mode),
              let string = JSValueToStringCopy(ctx, text.jsValueRef, nil) else { return JSValue(nullIn: context) }
        defer { JSStringRelease(string) }
        guard let linesObject = JSValueToObject(ctx, lines.jsValueRef, nil),
              JSValueGetTypedArrayType(ctx, lines.jsValueRef, nil) == kJSTypedArrayTypeInt32Array,
              let linesBytes = JSObjectGetTypedArrayBytesPtr(ctx, linesObject, nil) else { return JSValue(nullIn: context) }
        let lineList = UnsafeBufferPointer(start: linesBytes.assumingMemoryBound(to: Int32.self),
                                           count: JSObjectGetTypedArrayLength(ctx, linesObject, nil))
        let result = plan(UnsafeBufferPointer(start: JSStringGetCharactersPtr(string), count: JSStringGetLength(string)),
                          lines: lineList, mode: mode, tabSize: Int32(tabSize), unit: Int32(unit))
        guard let array = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeInt32Array, result.count, nil) else {
            return JSValue(nullIn: context)
        }
        if !result.isEmpty, let bytes = JSObjectGetTypedArrayBytesPtr(ctx, array, nil) {
            result.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        return JSValue(jsValueRef: array, in: context)
    }
}

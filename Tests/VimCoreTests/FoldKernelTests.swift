import Testing
@_spi(Benchmarks) @testable import VimCore

/// The JavaScript, Swift and Goose fold kernels must find the same blocks.
@MainActor
struct FoldKernelTests {
    nonisolated static let tricky: [String] = [
        "",
        "\n",
        "x",
        "func a() {\n    b\n}",
        "func a() {\n    b\n}\n",
        "a\n\n    b\n\n\n    c\nd",
        "\tif x {\n\t\ty\n\t}\n  \tz",
        "do\n  x\nend",
        "do\n  x\nendif",
        "do\n  x\nend_x\nend.",
        "f(\n  1,\n  2\n)\n[\n  3\n]",
        "a\r\n  b\r\n\r\nc\r\n",
        "\u{00A0}\u{00A0}a\n\u{00A0}\u{00A0}\u{00A0}b\n\u{3000}c",
        "a\n \u{2003}\n  b\n\u{FEFF}",
        "outer {\n  inner {\n    deep\n  }\n  more\n}\nnext {\n}",
        "    starts indented\n  less\nleast\n        most\n",
        "ы {\n    ünïcode 😀\n}",
    ]

    private func blocks(_ engine: VimEngine, _ kernel: VimFoldKernel) -> [ClosedRange<Int>] {
        engine.runtime.foldKernel = kernel
        return engine.foldBlocks()
    }

    @Test(arguments: tricky)
    func kernelsAgree(text: String) {
        let engine = VimEngine(text: text, runtime: VimRuntime())
        let js = blocks(engine, .javascript)
        #expect(blocks(engine, .swift) == js, "Swift kernel on \(text.debugDescription)")
        #expect(blocks(engine, .goose) == js, "Goose kernel on \(text.debugDescription)")
    }

    /// The native kernels called directly, so a silent fallback to
    /// JavaScript in the engine could not hide a difference.
    @Test(arguments: tricky)
    func nativeKernelsCalledDirectly(text: String) {
        let js = blocks(VimEngine(text: text, runtime: VimRuntime()), .javascript)
        let scanner = VimFoldBlockScanner()
        let utf16 = Array(text.utf16)
        for kernel in [VimFoldKernel.swift, .goose] {
            let flat = utf16.withUnsafeBufferPointer { scanner.blocks(in: $0, tabSize: 4, kernel: kernel) }
            let ranges = stride(from: 0, to: flat.count - 1, by: 2).map { Int(flat[$0])...Int(flat[$0 + 1]) }
            #expect(ranges == js, "\(kernel) on \(text.debugDescription)")
        }
    }

    @Test func kernelsAgreeWithTabSize() {
        let engine = VimEngine(text: "\ta\n    b\n\t  c\n  \td", runtime: VimRuntime())
        for size in [1, 2, 3, 4, 8] {
            engine.setOption("tabSize", size)
            let js = blocks(engine, .javascript)
            #expect(blocks(engine, .swift) == js, "tabSize \(size)")
            #expect(blocks(engine, .goose) == js, "tabSize \(size)")
        }
    }

    @Test func kernelsAgreeOnRandomText() {
        let indents = ["", " ", "  ", "    ", "\t", "\t ", " \t", "\u{00A0}", "        "]
        let bodies = ["x", "}", ")", "]", "end", "end;", "endif", "end_", "", "\r", "a b", "{", "😀"]
        let engine = VimEngine(text: "", runtime: VimRuntime())
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let lineCount = Int.random(in: 0...40, using: &generator)
            let text = (0..<lineCount).map { _ in
                indents.randomElement(using: &generator)! + indents.randomElement(using: &generator)!
                    + bodies.randomElement(using: &generator)!
            }.joined(separator: "\n")
            engine.setText(text)
            let js = blocks(engine, .javascript)
            let swift = blocks(engine, .swift), goose = blocks(engine, .goose)
            #expect(swift == js, "Swift kernel on \(text.debugDescription)")
            #expect(goose == js, "Goose kernel on \(text.debugDescription)")
            if swift != js || goose != js { return }
        }
    }

    @Test func zMFoldsTheSameWithEveryKernel() {
        let text = (0..<300).map { "func f\($0)() {\n    if x {\n        y\n    }\n}" }.joined(separator: "\n")
        var results: [[VimFold]] = []
        for kernel in VimFoldKernel.allCases {
            let runtime = VimRuntime()
            runtime.foldKernel = kernel
            let engine = VimEngine(text: text, runtime: runtime)
            engine.feed("zM")
            results.append(engine.folds)
        }
        #expect(results[0].count == 300)
        #expect(results[1] == results[0])
        #expect(results[2] == results[0])
    }
}

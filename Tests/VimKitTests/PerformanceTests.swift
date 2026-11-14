import AppKit
import Foundation
import Testing
@testable import VimCore
@testable import VimKit

/// Per-key latency on a large document, through the real text view in a window.
/// Run with `VIMKIT_BENCH=1 swift test --filter PerformanceTests` to print a table.
///
/// The limits are generous (debug build, slow machines); they catch
/// accidental O(n²) behaviour, not small regressions. The first jump to the
/// end of a document lays out all of it once, so limits apply to the median.
@MainActor
@Suite(.serialized)
struct PerformanceTests {
    static let printsTable = ProcessInfo.processInfo.environment["VIMKIT_BENCH"] != nil

    struct Scenario {
        let name: String
        let setup: String
        let keys: String
        let repeats: Int
        /// Limit for the median, in milliseconds.
        var limit: Double = 30
    }

    static let scenarios: [Scenario] = [
        .init(name: "j", setup: "", keys: "j", repeats: 200),
        .init(name: "k", setup: "G", keys: "k", repeats: 200),
        .init(name: "w", setup: "", keys: "w", repeats: 200),
        .init(name: "G / gg", setup: "", keys: "Ggg", repeats: 10),
        .init(name: "<C-d>", setup: "", keys: "<C-d>", repeats: 50),
        .init(name: "<C-f>", setup: "", keys: "<C-f>", repeats: 50),
        .init(name: "gj (wrapped)", setup: "", keys: "gj", repeats: 100),
        .init(name: "x", setup: "1000G", keys: "x", repeats: 100),
        .init(name: "dd", setup: "1000G", keys: "dd", repeats: 50),
        .init(name: "u", setup: "1000G50x", keys: "u", repeats: 50),
        .init(name: "p", setup: "1000Gyy", keys: "p", repeats: 50),
        .init(name: ">>", setup: "1000G", keys: ">>", repeats: 50),
        .init(name: "insert typing", setup: "1000Gi", keys: "a", repeats: 200),
        .init(name: "o<Esc>", setup: "1000G", keys: "o<Esc>", repeats: 50),
        .init(name: "/search<CR>", setup: "", keys: "/label 1234<CR>", repeats: 5, limit: 300),
        .init(name: "n", setup: "/note 5<CR>", keys: "n", repeats: 100),
        .init(name: "*", setup: "1000Gw", keys: "*", repeats: 20),
        .init(name: "VGy (whole file)", setup: "gg", keys: "VGy", repeats: 3, limit: 300),
        .init(name: ":%s/value/item/g", setup: "", keys: ":%s/value/item/g<CR>u", repeats: 2, limit: 5_000),
        .init(name: "ciw", setup: "1000Gw", keys: "ciwabc<Esc>", repeats: 50),
        .init(name: ".", setup: "1000Gwciwabc<Esc>j", keys: ".j", repeats: 50),
    ]

    @Test(arguments: [20_000])
    func perKeyLatency(lines: Int) throws {
        let text = sampleCode(lines: lines)
        var rows: [(String, Double, Double)] = []
        for scenario in Self.scenarios {
            let editor = EditorWindow(text: text)
            editor.type(scenario.setup)
            let events = EditorWindow.events(scenario.keys)
            var samples: [Double] = []
            for _ in 0..<scenario.repeats {
                let start = ContinuousClock.now
                for event in events { editor.view.keyDown(with: event) }
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            let worst = samples.last ?? 0
            rows.append((scenario.name, median, worst))
            #expect(median < scenario.limit, "\(scenario.name): \(median) ms per repeat")
            #expect(editor.view.string == editor.view.vim.text, "\(scenario.name): view out of sync")
            editor.window.close()
        }
        if Self.printsTable {
            print("\n\(lines) lines, \(text.utf16.count / 1024) KB — ms per repeat (median / max)")
            for (name, median, worst) in rows {
                print(String(format: "%-20@ %8.2f %8.2f", name as NSString, median, worst))
            }
        }
    }
}

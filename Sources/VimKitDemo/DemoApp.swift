#if os(macOS)
import AppKit
import SwiftUI
import VimKit

@main
struct VimKitDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("VimKit Demo") {
            DemoView()
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct DemoView: View {
    enum Document: String, CaseIterable, Identifiable {
        case sample = "Sample"
        case large = "20,000 lines"
        case file = "File…"
        var id: Self { self }
    }

    @State private var text = DemoView.sample
    @State private var document = Document.sample
    @State private var fileName: String?
    @State private var vimEnabled = true
    @State private var lineNumbers = VimLineNumbers.hybrid
    @State private var cursorLine = true
    @State private var savedAt: Date?
    @State private var subtitle = DemoView.describe("Sample", DemoView.sample)

    var body: some View {
        VimEditor(text: $text)
            .vimEnabled(vimEnabled)
            .vimLineNumbers(lineNumbers)
            .vimCursorLine(cursorLine)
            .vimOnSave { savedAt = .now }
            .navigationSubtitle(subtitle)
            .toolbar {
                if let savedAt {
                    Text("Saved \(savedAt.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Picker("Text", selection: $document) {
                    ForEach(Document.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Line numbers", selection: $lineNumbers) {
                    Text("No numbers").tag(VimLineNumbers.off)
                    Text("Numbers").tag(VimLineNumbers.absolute)
                    Text("Relative").tag(VimLineNumbers.relative)
                    Text("Hybrid").tag(VimLineNumbers.hybrid)
                }
                Toggle("Cursor line", isOn: $cursorLine)
                Toggle("Vim", isOn: $vimEnabled)
                    .toggleStyle(.switch)
            }
            .onChange(of: document) { old, new in load(new, previous: old) }
    }

    /// Computed when a text is loaded, not on every keystroke.
    static func describe(_ name: String, _ text: String) -> String {
        let lines = text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        return "\(name) — \(lines.formatted()) lines, \((text.utf8.count / 1024).formatted()) KB"
    }

    private func load(_ document: Document, previous: Document) {
        switch document {
        case .sample: text = Self.sample
        case .large: text = Self.large
        case .file:
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url,
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else {
                self.document = previous
                return
            }
            fileName = url.lastPathComponent
            text = contents
        }
        subtitle = Self.describe(document == .file ? (fileName ?? "") : document.rawValue, text)
    }

    /// About 20,000 lines of Swift-like code: brackets, strings with brackets,
    /// comments, long lines that wrap, and blank lines between functions.
    static let large: String = {
        var lines = ["// VimKit large-file demo: 20,000 lines. Try G, gg, <C-d>, zz, :%s/value/item/g, u."]
        var index = 0
        while lines.count < 20_000 {
            let name = "function\(index)"
            lines.append("/// Computes \(name). See also function\(max(0, index - 1)) (search with * on the name).")
            lines.append("func \(name)(input: [Int], label: String = \"label (\(index))\") -> Int {")
            lines.append("    var value = input.reduce(0, +) // note \(index % 97)")
            lines.append("    if value > \(index * 3) {")
            lines.append("        value = compute(value, \"brackets in a string: ) ] }\", [\(index), \(index + 1)])")
            lines.append("    } else {")
            lines.append("        /* a block comment with ( unmatched brackets */")
            lines.append("        value -= \(index % 13)")
            lines.append("    }")
            if index % 5 == 0 {
                lines.append("    // A long line that wraps in a narrow window: " + String(repeating: "lorem ipsum dolor sit amet ", count: 8))
            }
            lines.append("    return value")
            lines.append("}")
            lines.append("")
            index += 1
        }
        return lines.prefix(20_000).joined(separator: "\n")
    }()

    static let sample = """
    VimKit demo — this text view runs the vim engine from codemirror-vim.

    Try:
      hjkl  w b e  0 $  gg G  %  f( ;     motions
      dw  ciw  di(  yy p  x .  >>  J      operators, text objects, repeat
      v V <C-v>  then d / y / I           visual modes
      qa ... q  then @a                   macros
      /needle<CR>  n N  *                 search
      :%s/needle/thread/g<CR>             ex commands
      :w<CR>                              save callback (see the toolbar)
      u  <C-r>                            undo / redo
      zc zo za  zM zR  zf2j               folds

    Non-Latin keyboard layouts work for commands: physical keys are used.

    func greet(name: String) -> String {
        return "Hello, " + name + "!" // needle
    }
    """
}
#else
/// The demo is a macOS app; on other platforms this target does nothing.
@main enum VimKitDemoUnsupported {
    static func main() {}
}
#endif

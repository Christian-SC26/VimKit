import SwiftUI
import UniformTypeIdentifiers
import VimKit

@main
struct VimKitDemoApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { DemoView() }
        }
    }
}

struct DemoView: View {
    enum Document: String, CaseIterable, Identifiable {
        case sample = "Sample"
        case large = "20,000 lines"
        var id: Self { self }
    }

    @State private var text = DemoView.sample
    @State private var document = Document.sample
    @State private var vimEnabled = true
    @State private var savedAt: Date?
    @State private var importing = false
    @State private var title = "Sample"

    var body: some View {
        VimEditor(text: $text)
            .vimEnabled(vimEnabled)
            .vimOnSave { savedAt = .now }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Text", selection: $document) {
                        ForEach(Document.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Open…", systemImage: "folder") { importing = true }
                    if !Document.allCases.map(\.rawValue).contains(title) {
                        Text(title).font(.headline).lineLimit(1)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let savedAt {
                        Text("Saved \(savedAt.formatted(date: .omitted, time: .standard))")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Vim", isOn: $vimEnabled)
                }
            }
            .onChange(of: document) { _, new in
                text = new == .sample ? Self.sample : Self.large
                title = new.rawValue
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .sourceCode, .text, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    text = contents
                    title = url.lastPathComponent
                }
            }
    }

    static let sample = """
    VimKit demo — this text view runs the vim engine from codemirror-vim.

    With a hardware keyboard (no Esc key? use Ctrl-[ or map Caps Lock
    to Escape in Settings › General › Keyboard › Hardware Keyboard):
      hjkl  w b e  0 $  gg G  %  f( ;     motions (hold a key to repeat)
      dw  ciw  di(  yy p  x .  >>  J      operators, text objects, repeat
      v V <C-v>  then d / y / I           visual modes
      qa ... q  then @a                   macros
      /needle<CR>  n N  *                 search
      :%s/needle/thread/g<CR>             ex commands
      :w<CR>                              save callback (see the toolbar)
      u  <C-r>  ⌘Z                        undo / redo

    With the on-screen keyboard, letters typed in normal mode are commands:
    tap i to type, and use the toolbar toggle to turn Vim off.

    func greet(name: String) -> String {
        return "Hello, " + name + "!" // needle
    }
    """

    /// About 20,000 lines of Swift-like code.
    static let large: String = {
        var lines = ["// VimKit large-file demo: 20,000 lines. Try G, gg, <C-d>, zz, :%s/value/item/g, u."]
        var index = 0
        while lines.count < 20_000 {
            lines.append("/// Computes function\(index). See also function\(max(0, index - 1)).")
            lines.append("func function\(index)(input: [Int], label: String = \"label (\(index))\") -> Int {")
            lines.append("    var value = input.reduce(0, +) // note \(index % 97)")
            lines.append("    if value > \(index * 3) {")
            lines.append("        value = compute(value, \"brackets in a string: ) ] }\", [\(index), \(index + 1)])")
            lines.append("    } else {")
            lines.append("        value -= \(index % 13)")
            lines.append("    }")
            if index % 5 == 0 {
                lines.append("    // A long line that wraps: " + String(repeating: "lorem ipsum dolor sit amet ", count: 8))
            }
            lines.append("    return value")
            lines.append("}")
            lines.append("")
            index += 1
        }
        return lines.prefix(20_000).joined(separator: "\n")
    }()
}

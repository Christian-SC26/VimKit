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
    @State private var text = DemoView.sample
    @State private var vimEnabled = true
    @State private var savedAt: Date?

    var body: some View {
        VimEditor(text: $text)
            .vimEnabled(vimEnabled)
            .vimOnSave { savedAt = .now }
            .toolbar {
                if let savedAt {
                    Text("Saved \(savedAt.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Toggle("Vim", isOn: $vimEnabled)
                    .toggleStyle(.switch)
            }
    }

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

    Non-Latin keyboard layouts work for commands: physical keys are used.

    func greet(name: String) -> String {
        return "Hello, " + name + "!" // needle
    }
    """
}

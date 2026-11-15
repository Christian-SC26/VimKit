#if os(macOS) || (canImport(UIKit) && !os(watchOS))
import SwiftUI
#if os(macOS)
import AppKit
public typealias VimPlatformFont = NSFont
#else
import UIKit
public typealias VimPlatformFont = UIFont
#endif

/// A SwiftUI text editor with Vim keybindings and an optional status line.
///
/// ```swift
/// VimEditor(text: $source)
///     .vimOnSave { try? source.write(to: url, atomically: true, encoding: .utf8) }
/// ```
public struct VimEditor: View {
    @Binding private var text: String
    private var configuration: Configuration
    @State private var status = VimStatus()

    public struct Configuration {
        public var font: VimPlatformFont
        public var options: VimOptions
        public var isVimEnabled: Bool
        public var showsStatusLine: Bool
        public var textInset: CGSize
        public var onSave: (() -> Void)?
        public var onExCommand: ((VimExCommand) -> Void)?

        #if os(macOS)
        public static let defaultFontSize: CGFloat = 13
        #else
        public static let defaultFontSize: CGFloat = 15
        #endif

        public init(
            font: VimPlatformFont = .monospacedSystemFont(ofSize: Self.defaultFontSize, weight: .regular),
            options: VimOptions = VimOptions(),
            isVimEnabled: Bool = true,
            showsStatusLine: Bool = true,
            textInset: CGSize = CGSize(width: 6, height: 8),
            onSave: (() -> Void)? = nil,
            onExCommand: ((VimExCommand) -> Void)? = nil
        ) {
            self.font = font
            self.options = options
            self.isVimEnabled = isVimEnabled
            self.showsStatusLine = showsStatusLine
            self.textInset = textInset
            self.onSave = onSave
            self.onExCommand = onExCommand
        }
    }

    public init(text: Binding<String>, configuration: Configuration = Configuration()) {
        _text = text
        self.configuration = configuration
    }

    public var body: some View {
        VStack(spacing: 0) {
            VimTextViewRepresentable(text: $text, status: $status, configuration: configuration)
            if configuration.showsStatusLine && configuration.isVimEnabled {
                Divider()
                VimStatusLine(status: status)
            }
        }
    }

    /// Called for `:w`.
    public func vimOnSave(_ action: @escaping () -> Void) -> VimEditor {
        var copy = self
        copy.configuration.onSave = action
        return copy
    }

    /// Turns Vim behaviour on or off.
    public func vimEnabled(_ enabled: Bool) -> VimEditor {
        var copy = self
        copy.configuration.isVimEnabled = enabled
        return copy
    }
}

/// A one-line Vim status bar: mode, command line, messages and pending keys.
public struct VimStatusLine: View {
    public var status: VimStatus

    public init(status: VimStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let line = status.commandLine {
                let cursor = min(max(line.cursor, 0), line.text.utf16.count)
                let index = String.Index(utf16Offset: cursor, in: line.text)
                Text("\(line.prefix)\(String(line.text[..<index]))\(Text("▏").foregroundStyle(.tint))\(String(line.text[index...]))")
                if !line.description.isEmpty {
                    Text(line.description).foregroundStyle(.secondary)
                }
            } else if let message = status.message {
                Text(message).foregroundStyle(status.messageIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            } else {
                Text(status.mode.label + (status.isInsertModeReturn ? " (C-O)" : "")).bold()
                if let banner = status.banner {
                    Text(banner).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(status.pendingKeys).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.bar)
    }
}

#if os(macOS)
struct VimTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var status: VimStatus
    var configuration: VimEditor.Configuration

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = VimTextView(options: configuration.options)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = configuration.textInset
        textView.font = configuration.font
        textView.string = text
        textView.isVimEnabled = configuration.isVimEnabled
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        textView.onStatusChange = { [weak coordinator] status in coordinator?.statusChanged(status) }
        textView.onSave = { [weak coordinator] in coordinator?.parent.configuration.onSave?() }
        textView.onExCommand = { [weak coordinator] command in coordinator?.parent.configuration.onExCommand?(command) }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? VimTextView else { return }
        if textView.string != text { textView.string = text }
        if textView.font != configuration.font { textView.font = configuration.font }
        if textView.textContainerInset != configuration.textInset { textView.textContainerInset = configuration.textInset }
        if textView.isVimEnabled != configuration.isVimEnabled { textView.isVimEnabled = configuration.isVimEnabled }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimTextViewRepresentable

        init(_ parent: VimTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let text = textView.string
            if parent.text != text { parent.text = text }
        }

        func statusChanged(_ status: VimStatus) {
            // Status can change while SwiftUI updates the view (e.g. setting
            // `string`), so publish it on the next turn of the run loop.
            Task { @MainActor [weak self] in
                guard let self, self.parent.status != status else { return }
                self.parent.status = status
            }
        }
    }
}
#else
struct VimTextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var status: VimStatus
    var configuration: VimEditor.Configuration

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> VimUITextView {
        let textView = VimUITextView(options: configuration.options)
        apply(configuration, to: textView)
        textView.text = text
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onStatusChange = { [weak coordinator] status in coordinator?.statusChanged(status) }
        textView.onSave = { [weak coordinator] in coordinator?.parent.configuration.onSave?() }
        textView.onExCommand = { [weak coordinator] command in coordinator?.parent.configuration.onExCommand?(command) }
        return textView
    }

    func updateUIView(_ textView: VimUITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text { textView.text = text }
        apply(configuration, to: textView)
    }

    private func apply(_ configuration: VimEditor.Configuration, to textView: VimUITextView) {
        if textView.font != configuration.font { textView.font = configuration.font }
        let inset = UIEdgeInsets(
            top: configuration.textInset.height, left: configuration.textInset.width,
            bottom: configuration.textInset.height, right: configuration.textInset.width
        )
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        if textView.isVimEnabled != configuration.isVimEnabled { textView.isVimEnabled = configuration.isVimEnabled }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: VimTextViewRepresentable

        init(_ parent: VimTextViewRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let text = textView.text ?? ""
            if parent.text != text { parent.text = text }
        }

        func statusChanged(_ status: VimStatus) {
            Task { @MainActor [weak self] in
                guard let self, self.parent.status != status else { return }
                self.parent.status = status
            }
        }
    }
}
#endif
#endif

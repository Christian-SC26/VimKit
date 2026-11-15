# VimKit

Vim keybindings for native Swift text views.

VimKit runs the mature, editor-agnostic Vim engine from
[codemirror-vim](https://github.com/replit/codemirror-vim) (the one used by
Replit, Obsidian and many CodeMirror-based editors) inside JavaScriptCore,
and connects it to `NSTextView` through a small adapter. You get real Vim
behaviour — motions, operators, text objects, registers, macros, marks,
`.` repeat, visual/block modes, search, `:s`, `:g`, `:normal`, mappings —
without writing a Vim implementation.

```swift
import VimKit

struct ContentView: View {
    @State private var text = ""

    var body: some View {
        VimEditor(text: $text)
            .vimOnSave { save(text) }   // :w
    }
}
```

## Products

| Product | Platforms | What it is |
|---|---|---|
| `VimCore` | macOS 14+, iOS 17+ | `VimEngine`: the headless engine. Feed it keys, it edits text and tells a delegate. |
| `VimKit` | macOS 14+, iOS 17+ | `VimTextView` (an `NSTextView` subclass, TextKit 2), `VimUITextView` (a `UITextView` subclass, TextKit 2), and `VimEditor` and `VimStatusLine` for SwiftUI. Re-exports `VimCore`. |

Add the package in Xcode (*File → Add Package Dependencies…*) or in `Package.swift`:

```swift
.package(url: "https://github.com/Christian-SC26/VimKit.git", from: "0.1.0")
```

## Usage

### SwiftUI

```swift
VimEditor(
    text: $text,
    configuration: .init(
        font: .monospacedSystemFont(ofSize: 14, weight: .regular),
        options: VimOptions(tabSize: 2, shiftWidth: 2, lineComment: "//"),
        onExCommand: { command in print(command.name, command.args) }
    )
)
.vimEnabled(isVimOn)
```

### AppKit

```swift
let textView = VimTextView(options: VimOptions())
textView.onStatusChange = { status in statusLabel.stringValue = status.mode.label }
textView.onSave = { document.save() }
scrollView.documentView = textView
```

`VimTextView` works like any `NSTextView`: set `string`, `font`, `delegate`,
attributes for syntax highlighting, and so on. Key presses go to Vim first;
anything Vim does not consume (typing in insert mode, `⌘` shortcuts, IME
composition) reaches the text view normally. Edits and selection changes
are mirrored both ways, so mouse selection enters visual mode and typed
text becomes part of Vim's undo history and `.` repeat.

### Headless engine

```swift
let vim = VimEngine(text: "hello world")
vim.feed("wciwthere<Esc>")
vim.text        // "hello there"
vim.mode        // .normal
vim.execute("%s/hello/goodbye/")
```

Implement `VimEngineDelegate` to put the engine behind any text view
(UIKit, a custom TextKit view, a terminal UI). Only the editing and
selection callbacks are required in practice; the geometry callbacks
(`rectForCharacterAt`, `verticalMoveFrom`, …) make screen-line motions such
as `gj`, `H`, `zz` and `<C-d>` exact. Without them the engine treats each
logical line as one screen line.

### Configuration

```swift
let runtime = VimRuntime.shared
runtime.execute("set ignorecase smartcase")
runtime.noremap("Y", to: "y$")
runtime.map("jk", to: "<Esc>", mode: .insert)
runtime.source(vimrcContents)          // a vimrc-style script

vim.defineEx("quit", prefix: "q") { _ in window.close() }
```

Registers, mappings and options are shared by all editors in a runtime,
like in Vim. The `+` and `*` registers use the system pasteboard; set
`runtime.clipboard` to change that.

### Keyboard layouts

Commands follow the physical key, so `hjkl`, `dd`, `ciw` work on Russian,
Ukrainian, Greek and other non-Latin layouts without switching. Text typed in
insert mode and on the command line keeps the active layout. For finer
control use `runtime.setLangmap(...)`.

## How it works

```
NSTextView ⇄ VimTextView ⇄ VimEngine (Swift) ⇄ JavaScriptCore
                                                  ├─ vimkit-adapter.js  CodeMirror 5–style document model
                                                  └─ vim.js             codemirror-vim engine (unmodified)
```

* `vim.js` is vendored unchanged from `@replit/codemirror-vim-core`
  (see `Sources/VimCore/Resources`). It is written against a small
  CodeMirror 5 interface, which `vimkit-adapter.js` implements on top of a
  plain line array, with its own undo history, bookmarks and search.
* Offsets are UTF-16 code units on both sides, the same as `NSString`, so
  no index conversion is needed.
* The engine owns the authoritative text. Its edits are applied to the
  text view; the view's own edits (typing, paste, autocorrect) are reported
  back with `replaceCharacters(in:with:)`.

### Updating the engine

Copy `packages/codemirror-vim-core/vim.js` from a newer codemirror-vim
release over `Sources/VimCore/Resources/vim.js`. Copy that release's
`test/vim_test.js` over `Tests/VimCoreTests/Resources/vim_test.js`, then run
`swift test`.

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

* macOS: `swift build` and `swift test`. Performance limits are multiplied
  by `VIMKIT_PERF_SCALE=5` because CI machines are slower.
* iOS: the package tests on an iPad simulator, and a build of the iOS demo.

To run the iOS tests locally:

```sh
xcodebuild test -scheme VimKit-Package \
  -destination 'platform=iOS Simulator,name=<an iPad simulator>' \
  -test-timeouts-enabled YES
```

### Upstream test suite

`UpstreamSuiteTests` runs codemirror-vim's own test suite (716 cases)
through the adapter's real key path in JavaScriptCore. Currently 712 pass.
The 4 tests VimKit fails on purpose, each with its reason, are listed in
`Tests/VimCoreTests/Resources/upstream-known-failures.txt`. The test fails
on any other failure, and also when a listed test starts passing. Set
`VIMKIT_UPSTREAM_REPORT=/path/file.tsv` to write every failure with its
message to that file.

### Performance

Measured through `VimTextView` in a window, on a 20,000-line (1 MB) file
with line wrapping, debug build. Most commands take under 5 ms per key.
The first jump to the end of a file lays out the whole file once
(about 0.25 s). `:%s` over every line together with its undo takes about
1 s. Run `VIMKIT_BENCH=1 swift test --filter PerformanceTests` for the full
table.

How this is kept fast:

* The engine sends a command's edits to the view in one batch, inside one
  `NSTextStorage` editing session. Many edits (`:%s`, undoing it) are
  merged into a single replacement of the changed region.
* Line offsets update lazily, so a run of edits through the file costs
  O(lines) in total.
* `VimTextView` keeps exact TextKit 2 layout up to the furthest position it
  has measured. Without this, TextKit 2's estimated line heights would make
  `zb`, `H`, `L` and `<C-d>` land on the wrong line.

`WindowScenarioTests` checks text, cursor, scrolling and selection in a real
window. It covers `G`, search, `<C-d>`/`<C-u>`/`<C-f>`/`<C-b>`, `zt`/`zz`/`zb`,
`H`/`M`/`L`, `gj`/`gk`/`g0`/`g$` on wrapped lines, visual mode, `:%s` with
undo and redo, the block cursor, and insert-mode `.` repeat.

### Syntax awareness

`%` skips brackets inside strings and comments, and so do the quote text
objects, when the delegate implements
`vimEngine(_:tokenTypeAt:)`. That method returns `.string`, `.comment` or
`nil` for the character before an offset. `=` re-indents lines by bracket
depth.

`VimTextView` and `VimUITextView` implement it for you. Mark strings and
comments with the `.vimTokenType` attribute while highlighting syntax:

```swift
textStorage.addAttribute(.vimTokenType, value: VimTokenType.comment, range: commentRange)
```

Or answer directly with `textView.tokenTypeProvider = { offset in ... }`.

### Folding

`zc` closes the block around the cursor, `zo` opens it, `za` toggles,
`zM` / `zR` close and open everything, `zf{motion}` (or `zf` in visual mode)
folds any lines, and `zd` / `zE` delete folds. Blocks are found by
indentation; a closing bracket line at the header's indentation belongs to
the block, so `func f() {` … `}` folds to its header line. `j` and `k` step
over closed folds. A search or jump into a fold opens it, and an edit
inside a fold deletes it.

`VimTextView` and `VimUITextView` hide folded lines (through the text
content storage delegate, which they set when it is free) and show
"⋯ N lines" after the header. Other hosts read `VimEngine.folds` in
`vimEngineFoldsDidChange(_:)`.

Unlike Vim, an operator on a closed fold (`dd`, `yy`) acts on the header
line only, and opens the fold.

## Demo

macOS:

```sh
swift run VimKitDemo
```

iPad / iPhone: open `Demo/VimKitDemo.swiftpm` in Xcode and run it on a
simulator or a device. In the simulator, use the Mac keyboard as a hardware
keyboard (I/O › Keyboard › Connect Hardware Keyboard). Both demos can show a
20,000-line sample or open any text file.

### iPad

`VimUITextView` is the UIKit counterpart of `VimTextView`, and `VimEditor`
uses it on iOS.

* Hardware keys go through `pressesBegan`. Consumed keys repeat while held
  (`keyRepeatDelay` and `keyRepeatInterval`).
* iPad keyboards often have no Escape key. `Ctrl-[` works, or map Caps Lock
  to Escape in Settings › General › Keyboard › Hardware Keyboard ›
  Modifier Keys.
* With the on-screen keyboard, characters typed in normal or visual mode
  run as commands. Text from dictation, paste and IME reaches vim through
  the text storage.
* `⌘Z` / `⇧⌘Z` use vim's undo history. UIKit's undo manager is disabled
  while Vim is on.

## Status and roadmap

Working: everything in the test suite (`swift test`) plus the demo app —
motions, operators, text objects (including tags), registers (including
`+`), macros, counts, `.` repeat, visual / line / block modes, replace mode,
search with highlighting, ex commands, mappings, undo/redo grouping,
non-Latin layouts. 712 of the 716 tests in codemirror-vim's own suite pass.

Planned:

- [x] `VimUITextView` for iPadOS with a hardware keyboard
- [x] Run codemirror-vim's own test suite against the adapter
- [x] Syntax-aware `%` and text objects via a delegate hook
- [x] `tokenTypeAt` from text attributes (`.vimTokenType`)
- [x] Code folding (`zc`, `zo`, `za`, `zM`, `zR`, `zf`)
- [ ] Operators on a closed fold act on the whole fold
- [x] Block cursor drawn with inverted text instead of a translucent box

## License

MIT. The bundled `vim.js` is © Marijn Haverbeke and others, MIT licensed
(`Sources/VimCore/Resources/codemirror-vim-LICENSE.txt`).

# VimKit

Vim keybindings for native Swift text views.

VimKit runs the mature, editor-agnostic Vim engine from
[codemirror-vim](https://github.com/replit/codemirror-vim) (the one used by
Replit, Obsidian and many CodeMirror-based editors) inside JavaScriptCore,
and connects it to native Swift text views through a small adapter. You get real Vim
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
| `VimKit` | macOS 14+, iOS 17+ | `VimTextView` (an `NSView` that lays out and draws its text itself), `VimUITextView` (a `UITextView` subclass, TextKit 2), and `VimEditor` and `VimStatusLine` for SwiftUI. Re-exports `VimCore`. |

Add the package in Xcode (*File → Add Package Dependencies…*) or in `Package.swift`:

```swift
.package(url: "https://github.com/Christian-SC26/VimKit.git", from: "0.2.1")
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

`VimTextView` is a code view of its own rather than an `NSTextView`
subclass: set `string`, `font`, `textColor`, `textContainerInset` and
`wrapsLines`, color text with `.foregroundColor` attributes on `textStorage`,
and follow edits with `onTextChange` (or `NSText.didChangeNotification`).
Put it in an `NSScrollView`; it sizes itself to the clip view and the text.
Key presses go to Vim first; anything Vim does not consume (typing in insert
mode, `⌘` shortcuts, IME composition, dictation) goes through
`NSTextInputClient` and the standard editing commands, as in a text view. Edits and selection changes
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
runtime.execute("set clipboard=unnamed")
runtime.noremap("Y", to: "y$")
runtime.map("jk", to: "<Esc>", mode: .insert)
runtime.source(vimrcContents)          // a vimrc-style script

vim.defineEx("quit", prefix: "q") { _ in window.close() }
```

Registers, mappings and options are shared by all editors in a runtime,
like in Vim. The `+` and `*` registers use the system pasteboard; set
`runtime.clipboard` to change that.

### Registers

All of Vim's registers work: `""`, `"0`–`"9` (including the Vi rule that
`d%`, `d}`, `dn`… also go to `"1`, and `"1p..` pasting `"1`, `"2`, `"3`),
`"a`–`"z` and appending `"A`–`"Z`, `"-`, `"_`, the read-only `".`, `":`,
`"/`, `"%` and `"#` (the host's `fileName` and `alternateFileName`),
`"+` / `"*` (the system clipboard; `:set clipboard=unnamed` makes it the
default register) and `"=`, an expression (`"=6*7<CR>p`,
`<C-r>=strftime('%F')<CR>` in insert mode). `:registers` / `:display` list
them as Vim does, `:let @a = 'text'`, `:let @/ = 'pattern'` and `:echo`
take expressions, and `<C-r>{register}`, `<C-r><C-w>` work in the `:` and
`/` prompts. Visual `P` keeps the register.

Macros are text, as in Vim: `"qp` pastes `A;<Esc>j`, and after editing it
`"qy$` and `@q` run the new version. A macro replays its keys as typed
(searches, ex commands and `.` inside it work) and stops when a key fails,
so `999@q` ends at the last line.

```swift
vim.fileName = url.path                                  // "% and expand('%')
runtime.setRegister("a", to: VimRegister(text: "kept\n", kind: .linewise))
let saved = runtime.registerNames.compactMap { name in   // persist like shada
    runtime.register(name).map { (name, $0) }
}
```

### Line numbers (macOS)

`:set number`, `:set relativenumber` (both: the cursor line's own number
on the left, as in Vim) and `:set numberwidth` show a number column next
to the text; it stays in place when the text scrolls sideways. Relative
numbers count a closed fold as one line, like `j`. Clicking a number moves
to its line, dragging selects lines. The app sets it with
`VimEditor(...).vimLineNumbers(.hybrid)` or `textView.lineNumbers`.

`:set cursorline` highlights the cursor's line (`cursorLineColor`), all of
its wrapped rows; `:set cursorlineopt=screenline` only the row with the
cursor, `=number` only its number. As in Vim, the cursor line's number is
highlighted only with `cursorline`. `VimEditor(...).vimCursorLine()` or
`textView.highlightsCursorLine`.

### Keyboard layouts

Commands follow the physical key, so `hjkl`, `dd`, `ciw` work on Russian,
Ukrainian, Greek and other non-Latin layouts without switching. Text typed in
insert mode and on the command line keeps the active layout. For finer
control use `runtime.setLangmap(...)`.

## How it works

```
VimTextView (VimTextLayout + CoreText) ⇄ VimEngine (Swift) ⇄ JavaScriptCore
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
through the adapter's real key path in JavaScriptCore. Currently 703 pass.
The 13 tests VimKit fails on purpose, each with its reason, are listed in
`Tests/VimCoreTests/Resources/upstream-known-failures.txt`. The test fails
on any other failure, and also when a listed test starts passing. Set
`VIMKIT_UPSTREAM_REPORT=/path/file.tsv` to write every failure with its
message to that file.

### Vim oracle

`OracleTests` compares VimKit with real Vim 9.2. `Tests/Oracle/cases.txt`
lists 304 cases (starting text, cursor and keys) covering motions,
operators, text objects, visual and insert mode, ex commands, registers,
macros, numbers and undo. `Tests/Oracle/regenerate.sh` plays each case in a
fresh Vim and records the text, cursor, mode and unnamed register in
`Tests/VimCoreTests/Resources/oracle-expected.json`. The test replays the
keys in VimKit and compares. Vim is needed only to regenerate the file, not
to run the test. Currently 283 cases match Vim. The other 21 are listed by
cause in `Tests/VimCoreTests/Resources/oracle-known-divergences.txt`; that
list is the to-do list for matching Vim. The test fails on any other
difference, when a listed case starts to match, and when `cases.txt` changed
without a regenerate. Set `VIMKIT_ORACLE_REPORT=/path/file.txt` to write
every difference to that file. With `nvim` on `PATH` the script also writes
`Tests/Oracle/NEOVIM.md`, the cases where Neovim ends differently (14; they
come from its defaults: `nostartofline`, octal numbers off).

### Performance

Measured through `VimTextView` in a window, on a 20,000-line (1 MB) file
with line wrapping, debug build. Most commands take under 5 ms per key.
The first jump to the end of a file lays out the whole file once
(about 0.25 s). `:%s` over every line together with its undo takes about
1 s. Run `VIMKIT_BENCH=1 swift test --filter PerformanceTests` for the full
table.

For a full picture run the performance stand (release build, macOS):

```sh
swift run -c release VimKitBench            # 1,000 and 20,000 lines, ~4 min
swift run -c release VimKitBench --quick    # a quarter of the repeats
swift run -c release VimKitBench --help     # sizes, levels, filter, baseline
```

It runs about 90 operations (motions, search, operators, text objects,
visual mode, insert, undo, ex commands, macros, folds) plus lifecycle
costs (runtime, engine and view creation, memory per instance), at two
levels: `VimEngine` alone and `VimTextView` in a window including layout
and drawing. For each it records wall time (median, p95, max, first),
main-thread and process CPU, instructions, IPC, estimated energy, peak
and retained memory footprint, malloc growth and frames over 16.7 ms.
Every run is numbered and kept in `Benchmarks/history/run-NNN.json`, with
the language the measured change was written in and a note
(`--lang Swift --note "…"`); `Benchmarks/HISTORY.md` tracks the most
expensive operations run by run. The HTML report (`bench-results/report.html`)
compares with the previous run and charts any operation across the history.

How this is kept fast:

* The engine sends a command's edits to the view in one batch, inside one
  `NSTextStorage` editing session. Many edits (`:%s`, undoing it) are
  merged into a single replacement of the changed region.
* Line offsets update lazily, so a run of edits through the file costs
  O(lines) in total; this holds for edits that add or delete lines too
  (`:g/x/d`).
* Commands that change many lines at once (`>`, `<`, `=` over a range,
  undo and redo of large changes) update the document, cursors, marks,
  folds and the view in one pass instead of one edit per line.
* JavaScriptCore runs the adapter without a JIT (always so on iOS), so
  scans over the whole file are done in Swift: fold blocks for `zM` and
  indentation for `>`, `<`, `=` over 32 or more lines.
* `VimTextView` lays out text itself (`VimTextLayout`): every screen row
  has the same height, each line knows how many rows it wraps to (counted
  from glyph advances, typeset with CoreText only when it may wrap), and a
  Fenwick tree sums them. Every position and the document height are exact,
  so the scroller never jumps or rescales, and a jump anywhere costs
  O(log lines). Only visible lines are drawn. TextKit 2 estimates the height
  of text away from the screen and re-estimates it while scrolling, and
  exact TextKit 2 layout of 20,000 lines took ~300 ms after each far edit.

`WindowScenarioTests` checks text, cursor, scrolling and selection in a real
window. It covers `G`, search, `<C-d>`/`<C-u>`/`<C-f>`/`<C-b>`, `zt`/`zz`/`zb`,
`H`/`M`/`L`, `gj`/`gk`/`g0`/`g$` on wrapped lines, visual mode, `:%s` with
undo and redo, the block cursor, and insert-mode `.` repeat.

### Find bar, spelling and other text services (macOS)

`VimTextView` implements `NSTextFinderClient`, so the system find bar
works: ⌘F, ⌥⌘F (replace), ⌘G / ⇧⌘G and ⌘E, from the Edit › Find menu or
from the keys even if the app's menu has no Find items. The bar shows in
the enclosing scroll view; the text moves down under it, and Vim's screen
motions (`H`, `L`, `zt`, `<C-f>`) measure the text below it. Replace All is
sent to the engine (it is undone with `u`) and reported to the app once.
⌘E with nothing selected (always so in normal mode) takes the word under
the cursor, like `*`; then ⌘G finds it. Vim's own `/`, `n`, `:s` work as
before.

Set `isContinuousSpellCheckingEnabled` (or `checksSpelling` in
`VimEditor.Configuration`) to underline misspelled words. Visible lines are
checked in the background with `NSSpellChecker`, in the language it
detects; the context menu offers guesses, Ignore and Learn, and Edit ›
Spelling and Grammar works (⌘;, the Spelling panel). With
`spellCheckingScope = .stringsAndComments` only text marked by
`.vimTokenType` (or `tokenTypeProvider`) is checked, so identifiers are
not flagged.

The Services menu sends the selection and takes text back; selected text
can be dragged out, moved within the view (⌥ copies) and text or files
dropped in; force click or the context menu's Look Up shows the
dictionary. Lines read left to right, with Hebrew and Arabic runs laid out
right to left inside them (as in Xcode); the cursor, selection and clicks
follow the glyphs.

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
over closed folds, and linewise operators (`dd`, `yy`, `>>`, `cc`, `3dd`)
take a closed fold as one line, and so does `V`; `o` on a fold opens the
line after it. A search, mark, `%` or undo that lands in a fold opens it;
jumps (`G`, `gg`, `<C-d>`, `H`/`M`/`L`) keep it closed and put the cursor
on it, as with Vim's default `'foldopen'`.
Edits inside a fold keep it; an edit across its first or last line deletes
it.

`VimTextView` and `VimUITextView` hide folded lines (through the text
content storage delegate, which they set when it is free) and show
"⋯ N lines" after the header. Other hosts read `VimEngine.folds` in
`vimEngineFoldsDidChange(_:)`.

Blocks are found in Swift; `VimRuntime.foldKernel = .javascript` switches
to the adapter's JavaScript. Both find the same blocks; on 20,000 lines
Swift takes 0.62 ms and JavaScript 13 ms (`VimEngine.foldBlocks()`,
VimKitBench run 8). VimKitBench also measures the same kernel written in
Goose (`Kernels/fold_blocks.goose`, compiled to C in
`Sources/VimGooseKernels` by `Kernels/regenerate.sh`): 0.67 ms. Only the
stand and the tests link it; the libraries are Swift and JavaScript.

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

> **On hold.** Development currently focuses on macOS. `VimUITextView` is
> still a `UITextView` on TextKit 2, as in 0.2.1: it builds and passes its
> tests, but on long files the scroller can jump and far jumps after
> large edits are slow, because TextKit 2 estimates the height of text off
> screen. Moving it onto `VimTextLayout`, as on macOS, is planned — see
> [STATUS.md](STATUS.md#работа-на-будущее-ipad-и-iphone).

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

What is done and what is planned, in detail: [STATUS.md](STATUS.md).

Working: everything in the test suite (`swift test`) plus the demo app —
motions, operators, text objects (including tags), registers (including
`+`), macros, counts, `.` repeat, visual / line / block modes, replace mode,
search with highlighting, ex commands, mappings, undo/redo grouping,
non-Latin layouts, folding. 714 of the 716 tests in codemirror-vim's own suite pass.

Planned:

- [x] `VimUITextView` for iPadOS with a hardware keyboard
- [x] Run codemirror-vim's own test suite against the adapter
- [x] Syntax-aware `%` and text objects via a delegate hook
- [x] `tokenTypeAt` from text attributes (`.vimTokenType`)
- [x] Code folding (`zc`, `zo`, `za`, `zM`, `zR`, `zf`)
- [x] Linewise operators on a closed fold act on the whole fold
- [x] Visual line mode (`V`) selects a closed fold whole
- [x] Block cursor drawn with inverted text instead of a translucent box

## License

MIT. The bundled `vim.js` is © Marijn Haverbeke and others, MIT licensed
(`Sources/VimCore/Resources/codemirror-vim-LICENSE.txt`).

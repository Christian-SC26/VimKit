# Changelog

## Unreleased

- `VimKitBench`: a performance stand (`swift run -c release VimKitBench`)
  that measures time, CPU, instructions, energy and memory for every
  operation at the engine and view levels and writes an HTML report.
  Runs are numbered and kept in `Benchmarks/history` with the language and
  a note; `Benchmarks/HISTORY.md` follows the costliest operations.
- `zM` on large files: blocks are found in one pass and folds are added in
  bulk. 20,000 lines: 8.5 s → 43 ms in the engine.

## 0.2.1 — 2026-11-15

- `o` on a closed fold opens the line after the fold.
- Jumps into a closed fold (`G`, `gg`, `<C-d>`, `H`/`M`/`L`, `3G`) keep it
  closed and put the cursor on it; search, marks, `%` and undo open it, as
  with Vim's default `'foldopen'`.

## 0.2.0 — 2026-11-15

- Folding: `zc`, `zo`, `za`, `zM`, `zR`, `zf{motion}`, `zd`, `zE`. Blocks are
  found by indentation. The views hide folded lines and show "⋯ N lines";
  `j`/`k` step over closed folds. `VimEngine.folds` and
  `vimEngineFoldsDidChange(_:)` for other hosts.
- Linewise operators (`dd`, `yy`, `>>`, counts) take a closed fold as one
  line, and so does visual line mode; edits inside a fold keep it.
- The block cursor paints the character under it inverted, in live windows
  too (TextKit 2 is told to redraw the text under it).
- `.vimTokenType` text attribute and `tokenTypeProvider` for syntax-aware
  `%` and `=` in the views.
- codemirror-vim suite: 714 of 716 (the folding tests now pass).

## 0.1.0 — 2026-11-15

First release.

- `VimCore`: the codemirror-vim engine running in JavaScriptCore behind a
  CodeMirror-style adapter. Covers normal, insert, visual (char, line, block)
  and replace modes, operators and text objects, registers, macros, marks,
  search, ex commands (`:s`, `:g`, `:sort`, `:normal`, `:map`, …) and undo.
  Passes 712 of codemirror-vim's 716 tests; the 4 known failures are listed
  in `Tests/VimCoreTests/Resources/upstream-known-failures.txt`.
- `VimTextView` (AppKit) and `VimUITextView` (UIKit), both on TextKit 2:
  block cursor, search highlight, screen-relative motions (`<C-d>`, `zz`,
  `H`/`M`/`L`, `gj`), key repeat on iPad, non-Latin keyboard layouts.
- `VimEditor` and `VimStatusLine` for SwiftUI on macOS and iOS.
- Syntax-aware `%` and `=` through `vimEngine(_:tokenTypeAt:)`.
- Fast on large files: most commands on a 20,000-line file take under 5 ms;
  `:%s` over the whole file takes about a second.
- Demo apps for macOS (`swift run VimKitDemo`) and iPad
  (`Demo/VimKitDemo.swiftpm`).

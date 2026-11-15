# Changelog

## Unreleased

- Folding: `zc`, `zo`, `za`, `zM`, `zR`, `zf{motion}`, `zd`, `zE`. Blocks are
  found by indentation. The views hide folded lines and show "⋯ N lines";
  `j`/`k` step over closed folds. `VimEngine.folds` and
  `vimEngineFoldsDidChange(_:)` for other hosts.
- Linewise operators (`dd`, `yy`, `>>`, counts) take a closed fold as one
  line; edits inside a fold keep it.
- The block cursor paints the character under it inverted.
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

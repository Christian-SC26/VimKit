# Changelog

## Unreleased

- New `U` (undo all changes on the last changed line; `U` again redoes
  them, `u` undoes `U`), `gp` and `gP` (put and leave the cursor just after
  the new text).
- Visual mode as in Vim: `<C-a>` / `<C-x>` add `[count]` to the first number
  of each selected line (within the block or from the start column), and
  `g<C-a>` / `g<C-x>` add `[count]`, `2*[count]`, …; after `<C-v>I` and
  `<C-v>A` the cursor is at the top left of the block; a block yanked over a
  line that ends before it holds spaces as wide as the block.
- Text objects as in Vim: `i"` / `a"` skip escaped quotes, pair quotes from
  the start of the line and take the first string after the cursor; `a"`
  takes the white space after the string (or before it); `2i"` keeps the
  quotes. `[count]i(` / `[count]a(` take the count-th enclosing pair; `i{`
  over braces on their own lines is linewise. In characterwise visual mode
  a selection that reaches the end of a line (`v$`, `vi{`) takes the line
  break.
- Search offsets as in Vim: `/pat/e`, `e+1`, `s-1`, `b+2`, `/pat/+1` (line,
  linewise for operators; `e` is inclusive), remembered for `n` and `N`; with
  an `e` offset the search goes by the end of the match. New motions `g_`
  and `[count]go`.
- Search and `:s` patterns are Vim regular expressions by default
  (`'pcre'` is off): `\(\)`, `\+`, `\|`, `\<` `\>`, `\v`, `\zs`; `:set pcre`
  brings back JavaScript syntax. The `:s` replacement follows Vim: `&` is
  the match (`\&` a literal one), `\r` breaks the line, `\u` `\l` `\U`
  `\L` `\e` change case. New `:&` / `:&&` (with flags and a count), `&` and
  `g&`; `E33` without a previous substitute. After a replacement that breaks
  lines the cursor is on its last line. In `feed`, `<x>` without a modifier
  is three characters, as in Vim notation.
- Insert mode as in Vim: `<C-w>` and `<C-u>` leave the registers alone,
  stop once at the start of the insert and join lines at column 0; `<C-u>`
  keeps the indent; `<C-h>`, `<C-a>` (insert the last inserted text),
  `<C-y>` / `<C-e>` (character above / below); a cursor key starts a new
  undo step; `<BS>` in replace mode puts back what was overwritten.
  `VimEngine.feed` moves the cursor for arrow keys, Home and End in insert
  mode.
- More of Vim, found by the oracle: `:m`, `:t` / `:co`, `:>` / `:<` with
  ranges, counts and `>>`; `:j` with a range, a count and `!`; `:s` with a
  count (`:s/x/y/3`); `:m0`, `:t.`, `:d2` parse as in Vim. `J` adds no space
  before `)`, after trailing white space or onto an empty line. `<CR>` in
  insert mode follows 'autoindent' (the engine handles it, not the view):
  the new line gets the indent, the white space at the cursor goes, and an
  indent nothing was typed after is removed (`o<Esc>`, `cc<Esc>`,
  `<CR><CR>`); `r<CR>` leaves the cursor as Vim does.
- Matches Vim where the oracle showed it did not: in normal mode the cursor
  never ends past the last character (`~` at the end, `:normal A;`); `P`
  leaves it on the last pasted character; deleting through the last line
  (`dd` there, `dG`, `:$d`, `:g/x/d`) stores `line\n`, not `\nline\n`, and
  leaves no empty line; `:d` takes a register and a count (`:d a`, `:d 3`)
  and leaves the cursor on the next line; `:s` leaves it at the first
  non-blank of the last changed line, reports `E486` when nothing matches
  and no longer stops `:g` on a line without a match; "N lines yanked" only
  above 2 lines and no "Found N matches" after `:s` (unless the `n` flag);
  these messages are no longer reported as errors.
- Vim oracle: `OracleTests` replays 343 cases from `Tests/Oracle/cases.txt`
  and compares them with what real Vim 9.2 does, as recorded in
  `oracle-expected.json` by `Tests/Oracle/regenerate.sh`, which also lists
  where Neovim differs (`Tests/Oracle/NEOVIM.md`). 340 match; the 3
  differences are listed by cause in `oracle-known-divergences.txt`.
- Registers as in Vim: `"*`/`"+` on the clipboard (`'clipboard'`
  unnamed/unnamedplus), `"%`/`"#` from `VimEngine.fileName` /
  `alternateFileName`, the expression register `"=` (numbers, strings,
  `@r`, `&option`, operators and functions such as `strftime`, `printf`,
  `expand`, `line`), `:let @r`, `:echo`, `:registers`/`:display` in Vim's
  layout, `<C-r>{reg}` / `<C-r><C-w>` in the command line, `"1` for named
  deletes and Vi motions, `"1p..`, read-only registers refuse writes,
  visual `P` keeps the register. Macros are key text: they can be pasted,
  edited and run again, replay as typed and stop at the first failing key.
  `VimRuntime.register(_:)`, `setRegister(_:to:)`, `registerNames`.
- Cursor line on macOS: `:set cursorline` / `cursorlineopt` (line,
  screenline, number), `VimTextView.highlightsCursorLine`,
  `cursorLineColor`, `VimEditor.vimCursorLine()`. The cursor line's number
  is highlighted only with `cursorline`, as in Vim.
- Line numbers on macOS: `:set number` / `relativenumber` / `numberwidth`,
  `VimTextView.lineNumbers`, `VimEditor.vimLineNumbers(_:)`.
  `VimEngine.vimOption(_:)` / `setVimOption(_:_:)` read and set vim
  options; the delegate gets `vimEngine(_:didChangeOption:)`.
- macOS `VimTextView`: the system find bar (`NSTextFinder`: ⌘F, ⌥⌘F, ⌘G,
  ⇧⌘G, ⌘E, Replace All through the engine) and spell checking
  (`isContinuousSpellCheckingEnabled`, `spellCheckingScope`, guesses in the
  context menu, Edit › Spelling and Grammar). `VimEditor.Configuration`
  gets `checksSpelling`. The find bar no longer covers the first lines,
  and screen motions measure the text below it. ⌘E with nothing selected
  uses the word under the cursor.
- macOS `VimTextView`: the Services menu, dragging text out and in (files
  drop as paths), Look Up (force click, context menu), and right-to-left
  text: lines are left-to-right paragraphs, character boxes, clicks and
  selections follow the glyphs.
- **Breaking:** `VimTextView` (macOS) is now an `NSView` that lays out and
  draws its text itself instead of an `NSTextView` on TextKit 2. Positions
  and the document height are exact, so the scroller no longer jumps or
  changes scale on long files. It keeps input methods and dictation
  (`NSTextInputClient`), the standard editing commands, the Edit menu,
  mouse selection and accessibility (a text area). New API: `textStorage`
  (non-optional), `wrapsLines`, `textColor`, `backgroundColor`,
  `onTextChange`; gone: `NSTextView`/`NSText` members such as `delegate`,
  `textContainer`, `layoutManager`, `isVerticallyResizable`. 20,000 lines
  in the view: first `G` 285 → 0.3 ms, `ggVG>` 367 → 16 ms, `ggVG=`
  151 → 4 ms, `:%s/value/item/g` 463 → 124 ms.
- `VimKitBench`: a performance stand (`swift run -c release VimKitBench`)
  that measures time, CPU, instructions, energy and memory for every
  operation at the engine and view levels and writes an HTML report.
  Runs are numbered and kept in `Benchmarks/history` with the language and
  a note; `Benchmarks/HISTORY.md` follows the costliest operations.
- `zM` on large files: blocks are found in one pass and folds are added in
  bulk. 20,000 lines: 8.5 s → 43 ms in the engine.
- The block cursor is updated once per key instead of on every mode and
  selection change inside it: `:%norm A;` on 20,000 lines 7.6 s → 2.1 s.
- Fold labels ("⋯ N lines") are placed only near the visible text and
  follow scrolling: `zM` on 20,000 lines in the view 0.8 s → 48 ms.
- The engine reports edits, selection, mode and scrolling to the host once
  per key instead of after every operation vim.js runs inside it (`:normal`,
  macros, counts): `:%norm A;` on 20,000 lines 2.1 s → 1.5 s in the view.
- Fold blocks are found in Swift: `VimRuntime.foldKernel` (`.swift` by
  default, or `.javascript`) and `VimEngine.foldBlocks()`. 20,000 lines:
  13 ms in JavaScript, 0.62 ms in Swift; `zM` in the view 48 → 36 ms.
  VimKitBench compares it with the same kernel in Goose
  (`Kernels/fold_blocks.goose`, 0.67 ms), which the libraries do not link.
- `>`, `<` and `=` over many lines: the new columns are computed in Swift
  and the lines change in one batch (document, cursors, marks, folds, undo
  history and the view at once). Undo and redo of large changes are batched
  too. 20,000 lines in the engine: `ggVG>` 102 → 14 ms, `ggVG=` 60 → 4 ms,
  `u` after `:%s` 43 → 7 ms.
- Deleting or inserting lines no longer re-indexes the whole document:
  `:g/note 5/d` on 20,000 lines 155 → 13 ms; `dd`, `p`, `J`, `o` about 2×
  faster on large files.

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

" Vim oracle for VimKit: plays a case of cases.txt in real Vim (or Neovim)
" and records what it leaves behind (text, cursor, mode, unnamed register) as
" JSON. regenerate.sh starts a fresh Vim for every case, so nothing (last
" substitute, `.`, `;`, `@@`, jumps) leaks from one case into the next.
"
" The settings mirror what VimKit does: VimOptions defaults (tabSize 4,
" shiftWidth 4, expandTab), and new lines keep the indent (VimKit has no
" 'autoindent' option yet). Everything else is Vim's own default, so a
" difference from VimKit is a difference from Vim.

set nocompatible
set tabstop=4 shiftwidth=4 softtabstop=0 expandtab
set autoindent
set backspace=indent,eol,start
set noswapfile nobackup nowritebackup
set shortmess+=F

" Vim key notation ("ciwx<Esc>", "<C-r>a") to the keys themselves. Only
" <name> tokens are special; a lone < (as in "<<") stays a character.
function! s:Keys(notation) abort
  let s = escape(a:notation, '\"')
  let s = substitute(s, '<\([^<> ]\+\)>', '\\<\1>', 'g')
  return eval('"' . s . '"')
endfunction

function! s:Parse(path) abort
  let cases = []
  let names = {}
  let lnum = 0
  for line in readfile(a:path)
    let lnum += 1
    if line =~# '^\s*\(#.*\)\=$'
      continue
    elseif line =~# '^\[[^\]]\+\]$'
      let name = line[1:-2]
      if has_key(names, name)
        throw printf('cases.txt:%d: duplicate case [%s]', lnum, name)
      endif
      let names[name] = 1
      call add(cases, {'name': name, 'keys': '', 'at': [1, 1], 'text': []})
    elseif empty(cases)
      throw printf('cases.txt:%d: text before the first [case]', lnum)
    elseif line =~# '^|'
      call add(cases[-1].text, substitute(line, '^| \=', '', ''))
    elseif line =~# '^keys '
      let cases[-1].keys = line[5:]
    elseif line =~# '^at \d\+ \d\+$'
      let cases[-1].at = map(split(line[3:]), 'str2nr(v:val)')
    else
      throw printf('cases.txt:%d: expected [name], keys, at or | text: %s', lnum, line)
    endif
  endfor
  for c in cases
    if empty(c.text) | let c.text = [''] | endif
    if empty(c.keys) | throw printf('[%s] has no keys', c.name) | endif
  endfor
  return cases
endfunction

function! s:Play(case) abort
  " The starting text is not an undoable change.
  let undolevels = &undolevels
  set undolevels=-1
  call setline(1, a:case.text)
  let &undolevels = undolevels
  call setcursorcharpos(a:case.at[0], a:case.at[1])
  let error = ''
  try
    call feedkeys(s:Keys(a:case.keys), 'xt')
  catch
    let error = substitute(v:exception, '^Vim(\a\+):', '', '')
  endtry
  let type = getregtype('"')
  return {
        \ 'name': a:case.name,
        \ 'text': a:case.text,
        \ 'at': a:case.at,
        \ 'keys': a:case.keys,
        \ 'expected': {
        \   'text': getline(1, '$'),
        \   'line': line('.'),
        \   'column': charcol('.'),
        \   'mode': mode(1),
        \   'register': getreg('"'),
        \   'registerType': type[0] ==# "\<C-v>" ? 'b' . type[1:] : type,
        \   'error': error,
        \ }}
endfunction

function! s:Version() abort
  if has('nvim')
    return matchstr(execute('version'), 'NVIM v[^ \t\n]\+')
  endif
  return printf('Vim %d.%d.%04d', v:version / 100, v:version % 100, v:versionlong % 10000)
endfunction

" Writes the number of cases (and checks that cases.txt parses).
function! OracleCount(cases, out) abort
  call writefile([len(s:Parse(a:cases))], a:out)
endfunction

" Plays case number `index` (from 0) and appends its JSON line to `out`.
function! OraclePlay(cases, index, out) abort
  call writefile([json_encode(s:Play(s:Parse(a:cases)[a:index]))], a:out, 'a')
endfunction

" The oracle file from the lines OraclePlay wrote: one case per line, so a
" regenerated file diffs case by case.
function! OracleWrite(cases, body, out) abort
  let body = readfile(a:body)
  let lines = ['{',
        \ '"generator": ' . json_encode(s:Version()) . ',',
        \ '"casesSHA256": ' . json_encode(sha256(join(readfile(a:cases, 'b'), "\n"))) . ',',
        \ '"cases": [']
  call extend(lines, map(body, 'v:key < len(body) - 1 ? v:val . "," : v:val'))
  call extend(lines, [']', '}'])
  call writefile(lines, a:out)
endfunction

" Markdown table of the cases where two oracle files disagree (Vim vs Neovim).
function! OracleCompare(vim, nvim, out) abort
  let a = json_decode(join(readfile(a:vim), "\n"))
  let b = json_decode(join(readfile(a:nvim), "\n"))
  let theirs = {}
  for c in b.cases | let theirs[c.name] = c.expected | endfor
  let rows = []
  for c in a.cases
    let other = get(theirs, c.name, {})
    if c.expected == other | continue | endif
    let fields = filter(sort(keys(c.expected)), 'json_encode(get(other, v:val, "")) !=# json_encode(c.expected[v:val])')
    let Show = {e -> substitute(json_encode(map(copy(fields), {_, f -> f . '=' . json_encode(get(e, f, ''))})), '|', '\\|', 'g')}
    call add(rows, printf('| `%s` | `%s` | %s | %s |', c.name, escape(c.keys, '|'),
          \ Show(c.expected), Show(other)))
  endfor
  let lines = [
        \ '# Vim vs Neovim on cases.txt',
        \ '',
        \ 'Generated by `Tests/Oracle/regenerate.sh` from ' . a.generator . ' and ' . b.generator
        \ . ', both with the settings in `oracle.vim`. VimKit follows Vim; these are',
        \ 'the cases where Neovim, with its own defaults, ends differently.',
        \ '',
        \ printf('%d of %d cases differ.', len(rows), len(a.cases)),
        \ '']
  if !empty(rows)
    call extend(lines, ['| Case | Keys | Vim | Neovim |', '|---|---|---|---|'] + rows)
  endif
  call writefile(lines, a:out)
endfunction

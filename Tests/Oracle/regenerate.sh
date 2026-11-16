#!/bin/sh
# Regenerates the Vim oracle after editing cases.txt:
#   Tests/VimCoreTests/Resources/oracle-expected.json  (what Vim does; read by OracleTests)
#   Tests/Oracle/NEOVIM.md                             (where Neovim ends differently; needs nvim)
# Needs Vim 9 on PATH (VIM=/path/to/vim to pick another). Every case runs in
# its own Vim process, so no state leaks between cases.
set -eu
cd "$(dirname "$0")"
VIM=${VIM:-vim}
NVIM=${NVIM:-nvim}
out=../VimCoreTests/Resources/oracle-expected.json
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# $1 = binary, $2 = Vim command; the rest are flags. Fails on a Vim error.
vimdo() {
  bin=$1 cmd=$2; shift 2
  rm -f "$tmp/error"
  "$bin" -u NONE -i NONE -n "$@" -S oracle.vim \
    -c "try | $cmd | catch | call writefile([v:exception], '$tmp/error') | endtry" \
    -c 'qa!' </dev/null >/dev/null 2>&1 || true
  if [ -s "$tmp/error" ]; then echo "$bin: $(cat "$tmp/error")" >&2; exit 1; fi
}

# $1 = binary, $2 = output file; the rest are flags for playing keys.
play_all() {
  bin=$1 file=$2; shift 2
  : > "$tmp/body"
  i=0
  while [ "$i" -lt "$count" ]; do
    vimdo "$bin" "call OraclePlay('cases.txt', $i, '$tmp/body')" "$@"
    i=$((i + 1))
  done
  played=$(wc -l < "$tmp/body" | tr -d ' ')
  [ "$played" -eq "$count" ] || { echo "$bin played $played of $count cases" >&2; exit 1; }
  vimdo "$bin" "call OracleWrite('cases.txt', '$tmp/body', '$file')" "$@"
}

vimdo "$VIM" "call OracleCount('cases.txt', '$tmp/count')" -N -es
count=$(cat "$tmp/count")

play_all "$VIM" "$tmp/vim.json" -N -X --not-a-term
mv "$tmp/vim.json" "$out"
echo "wrote Tests/VimCoreTests/Resources/oracle-expected.json ($count cases)"

if command -v "$NVIM" >/dev/null 2>&1; then
  play_all "$NVIM" "$tmp/nvim.json" --headless
  vimdo "$VIM" "call OracleCompare('$out', '$tmp/nvim.json', 'NEOVIM.md')" -N -es
  echo "wrote Tests/Oracle/NEOVIM.md ($(sed -n 's/ of .* cases differ.//p' NEOVIM.md) cases differ in Neovim)"
fi

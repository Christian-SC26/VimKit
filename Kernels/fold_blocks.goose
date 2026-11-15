// Indentation blocks for VimKit's folds (zM), in Goose.
//
// The same algorithm exists in Swift (Sources/VimCore/FoldKernel.swift) and in
// JavaScript (`$allBlocksJS` in vimkit-adapter.js); VimKitBench compares them.
// Regenerate the C with Kernels/regenerate.sh.
//
// Text is UTF-16, as JavaScriptCore holds it, and lines are split on "\n" only,
// as the adapter's document does. A line is blank when it has nothing but
// JavaScript `\s` characters. Its indentation is the column after its leading
// `\s` characters (a tab moves to the next tab stop). A block starts on a
// non-blank line and takes the following lines indented deeper (blank lines
// inside it included), plus a closing line (`]`, `)`, `}` or the word `end`)
// at the header's own indentation.

// JavaScript's `\s`.
fn is_space(c: u16) -> bool {
    if c == 32 || (c >= 9 && c <= 13) { return true; }
    if c < 160 { return false; }
    return c == 160 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 ||
        c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF;
}

// JavaScript's `\w`, for the `\b` after `end`.
fn is_word(c: u16) -> bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

// The line's first non-space character is at `j` and the line ends at `e`.
fn is_closing(text: const u16[:], j: i64, e: i64) -> bool {
    let c = text[j];
    if c == 93 || c == 41 || c == 125 { return true; }      // ] ) }
    if j + 3 > e { return false; }
    if text[j] != 101 || text[j + 1] != 110 || text[j + 2] != 100 { return false; }  // "end"
    return j + 3 == e || !is_word(text[j + 3]);
}

// Writes, for every line, the last line of the block that starts on it, or -1.
// `last_of`, `stack_line` and `stack_indent` need one slot per line. Returns
// the number of lines.
export fn vimkit_fold_blocks(text: const u16[:], tab_size: i32, last_of: i32[:], stack_line: i32[:],
                             stack_indent: i32[:]) -> i32 {
    let n = text.len;
    var depth = 0;
    var prev: i32 = -1;
    var line: i32 = 0;
    var i: i64 = 0;
    while true {
        var col: i32 = 0;
        var j = i;
        var blank = true;
        while j < n && text[j] != 10 {
            let c = text[j];
            if !is_space(c) { blank = false; break; }
            if c == 9 { col = col + tab_size - col % tab_size; } else { col++; }
            j++;
        }
        var e = j;
        while e < n && text[e] != 10 { e++; }
        last_of[line] = -1;
        if !blank {
            var closing = -1;
            while depth > 0 && stack_indent[depth - 1] >= col {
                depth--;
                let header = stack_line[depth];
                var last = prev;
                if stack_indent[depth] == col {
                    if closing < 0 {
                        closing = 0;
                        if is_closing(text, j, e) { closing = 1; }
                    }
                    if closing == 1 { last = line; }
                }
                if last > header { last_of[header] = last; }
            }
            stack_line[depth] = line;
            stack_indent[depth] = col;
            depth++;
            prev = line;
        }
        line++;
        if e >= n { break; }
        i = e + 1;
    }
    while depth > 0 {
        depth--;
        let header = stack_line[depth];
        if prev > header { last_of[header] = prev; }
    }
    return line;
}

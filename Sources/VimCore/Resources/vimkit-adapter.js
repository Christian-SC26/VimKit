// VimKit adapter.
//
// A CodeMirror 5–shaped editor model that lets the editor-agnostic vim engine
// from @replit/codemirror-vim-core (vim.js, loaded before this file) run inside
// JavaScriptCore. The document text lives here; a native view mirrors it
// through the per-editor `host` object that Swift provides.
//
// Offsets are UTF-16 code unit indexes, which matches NSString exactly.
(function (global) {
  "use strict";

  var runtime = global.__vimkitRuntime;

  // ---------------------------------------------------------------------------
  // Environment shims (JavaScriptCore has no DOM, timers or console)
  // ---------------------------------------------------------------------------

  function stringify(value) {
    if (value instanceof Error) return value.stack ? value + "\n" + value.stack : String(value);
    if (typeof value === "object") {
      try { return JSON.stringify(value); } catch (e) { return String(value); }
    }
    return String(value);
  }
  function logger(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(stringify(arguments[i]));
      runtime.log(level, parts.join(" "));
    };
  }
  global.console = {
    log: logger("log"), info: logger("info"), debug: logger("debug"),
    warn: logger("warn"), error: logger("error")
  };

  var timers = Object.create(null);
  var nextTimer = 1;
  global.setTimeout = function (fn, ms) {
    var id = nextTimer++;
    timers[id] = fn;
    runtime.setTimer(id, +ms || 0);
    return id;
  };
  global.clearTimeout = function (id) {
    if (id && timers[id]) {
      delete timers[id];
      runtime.clearTimer(id);
    }
  };
  global.__vimkitFireTimer = function (id) {
    var fn = timers[id];
    if (!fn) return;
    delete timers[id];
    fn();
  };
  global.window = global;
  global.navigator = {
    platform: runtime.platform,
    userAgent: "VimKit",
    clipboard: {
      writeText: function (text) { runtime.clipboardWrite(String(text)); return Promise.resolve(); },
      // Resolves at once: vim.js pastes "+ in a then(), which must run within the key.
      readText: function () {
        var text = runtime.clipboardRead() || "";
        return { then: function (fn) { fn(text); } };
      }
    }
  };

  // Minimal DOM: vim.js builds prompt/notification templates with
  // document.createElement. We only need to read their text back.
  function VText(text) { this.nodeType = 3; this.parentNode = null; this.nodeValue = String(text); }
  Object.defineProperty(VText.prototype, "textContent", {
    get: function () { return this.nodeValue; },
    set: function (v) { this.nodeValue = String(v); }
  });
  VText.prototype.remove = function () { if (this.parentNode) this.parentNode.removeChild(this); };

  function VNode(tag) {
    this.nodeType = 1;
    this.tagName = String(tag).toUpperCase();
    this.childNodes = [];
    this.parentNode = null;
    this.style = {};
    this.attributes = {};
    this.className = "";
    this.value = "";
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this._listeners = {};
  }
  VNode.prototype.appendChild = function (child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  };
  VNode.prototype.removeChild = function (child) {
    var i = this.childNodes.indexOf(child);
    if (i >= 0) this.childNodes.splice(i, 1);
    child.parentNode = null;
    return child;
  };
  VNode.prototype.remove = function () { if (this.parentNode) this.parentNode.removeChild(this); };
  VNode.prototype.setAttribute = function (key, value) {
    this.attributes[key] = String(value);
    if (key === "class") this.className = String(value);
  };
  VNode.prototype.getAttribute = function (key) {
    return Object.prototype.hasOwnProperty.call(this.attributes, key) ? this.attributes[key] : null;
  };
  VNode.prototype.getElementsByTagName = function (tag) {
    var out = [], upper = String(tag).toUpperCase();
    (function walk(node) {
      for (var i = 0; i < node.childNodes.length; i++) {
        var c = node.childNodes[i];
        if (c.nodeType !== 1) continue;
        if (c.tagName === upper) out.push(c);
        walk(c);
      }
    })(this);
    return out;
  };
  VNode.prototype.querySelector = function (selector) {
    var cls = selector.charAt(0) === "." ? selector.slice(1) : null;
    var found = null;
    (function walk(node) {
      for (var i = 0; i < node.childNodes.length && !found; i++) {
        var c = node.childNodes[i];
        if (c.nodeType !== 1) continue;
        var match = cls ? (" " + c.className + " ").indexOf(" " + cls + " ") >= 0 : c.tagName === selector.toUpperCase();
        if (match) found = c; else walk(c);
      }
    })(this);
    return found;
  };
  VNode.prototype.contains = function (node) {
    for (; node; node = node.parentNode) if (node === this) return true;
    return false;
  };
  VNode.prototype.addEventListener = function (type, fn) {
    (this._listeners[type] = this._listeners[type] || []).push(fn);
  };
  VNode.prototype.removeEventListener = function (type, fn) {
    var list = this._listeners[type];
    if (list) { var i = list.indexOf(fn); if (i >= 0) list.splice(i, 1); }
  };
  VNode.prototype.focus = function () {};
  VNode.prototype.blur = function () {};
  VNode.prototype.select = function () {};
  Object.defineProperty(VNode.prototype, "textContent", {
    get: function () {
      var s = "";
      for (var i = 0; i < this.childNodes.length; i++) s += this.childNodes[i].textContent;
      return s;
    },
    set: function (v) {
      this.childNodes = [];
      if (v != null && v !== "") this.appendChild(new VText(v));
    }
  });
  Object.defineProperty(VNode.prototype, "innerText", {
    get: function () { return this.textContent; },
    set: function (v) { this.textContent = v; }
  });

  global.document = {
    createElement: function (tag) { return new VNode(tag); },
    createTextNode: function (text) { return new VText(text); },
    activeElement: null
  };

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------

  function Pos(line, ch, sticky) {
    this.line = line;
    this.ch = ch;
    if (sticky) this.sticky = sticky;
  }

  function on(emitter, type, f) {
    if (emitter.addEventListener) {
      emitter.addEventListener(type, f, false);
    } else {
      var map = emitter._handlers || (emitter._handlers = {});
      map[type] = (map[type] || []).concat(f);
    }
  }
  function off(emitter, type, f) {
    if (emitter.removeEventListener) {
      emitter.removeEventListener(type, f, false);
    } else {
      var map = emitter._handlers, arr = map && map[type];
      if (arr) {
        var index = arr.indexOf(f);
        if (index > -1) map[type] = arr.slice(0, index).concat(arr.slice(index + 1));
      }
    }
  }
  function signal(emitter, type) {
    var handlers = emitter._handlers && emitter._handlers[type];
    if (!handlers) return;
    var args = Array.prototype.slice.call(arguments, 2);
    for (var i = 0; i < handlers.length; ++i) handlers[i].apply(null, args);
  }
  function signalTo(handlers) {
    if (!handlers) return;
    var args = Array.prototype.slice.call(arguments, 1);
    for (var i = 0; i < handlers.length; ++i) handlers[i].apply(null, args);
  }

  var wordChar;
  try { wordChar = new RegExp("[\\w\\p{Alphabetic}\\p{Number}_]", "u"); } catch (e) { wordChar = /\w/; }

  function clamp(n, lo, hi) { return n < lo ? lo : n > hi ? hi : n; }
  function repeatString(s, n) { var out = ""; for (var i = 0; i < n; i++) out += s; return out; }

  // Maps an offset through the replacement of [from, to) by `len` characters.
  // assoc < 0 keeps a position at a pure insertion point before the inserted
  // text. mode "del" returns null for positions strictly inside a deletion;
  // mode "after" returns null when the character after the position is deleted.
  function mapPos(pos, from, to, len, assoc, mode) {
    if (pos < from) return pos;
    if (pos > to) return pos + len - (to - from);
    if (mode === "del" && pos > from && pos < to) return null;
    if (mode === "after" && to > from && pos < to) return null;
    var side = to === from ? assoc : pos === from ? -1 : pos === to ? 1 : assoc;
    return from + (side < 0 ? 0 : len);
  }

  var exNamePattern = /^(\w+|!!|@@|[!#&*<=>@~])/;
  var numericArgCommand = /^(m|mo|mov|move|t|co|cop|copy|d|de|del|dele|delet|delete|y|ya|yan|yank|j|jo|joi|join|pu|put)\d+$/;

  // CodeMirror 5 StringStream (used by vim.js to parse ex commands).
  function StringStream(string, tabSize) {
    this.pos = this.start = 0;
    this.string = string;
    this.tabSize = tabSize || 8;
    this.lineStart = 0;
  }
  StringStream.prototype = {
    eol: function () { return this.pos >= this.string.length; },
    sol: function () { return this.pos == this.lineStart; },
    peek: function () { return this.string.charAt(this.pos) || undefined; },
    next: function () { if (this.pos < this.string.length) return this.string.charAt(this.pos++); },
    eat: function (match) {
      var ch = this.string.charAt(this.pos), ok;
      if (typeof match == "string") ok = ch == match;
      else ok = ch && (match.test ? match.test(ch) : match(ch));
      if (ok) { ++this.pos; return ch; }
    },
    eatWhile: function (match) {
      var start = this.pos;
      while (this.eat(match)) {}
      return this.pos > start;
    },
    eatSpace: function () {
      var start = this.pos;
      while (/[\s ]/.test(this.string.charAt(this.pos))) ++this.pos;
      return this.pos > start;
    },
    skipToEnd: function () { this.pos = this.string.length; },
    skipTo: function (ch) {
      var found = this.string.indexOf(ch, this.pos);
      if (found > -1) { this.pos = found; return true; }
    },
    backUp: function (n) { this.pos -= n; },
    column: function () { return this.start - this.lineStart; },
    indentation: function () { return (/^\s*/.exec(this.string) || [""])[0].length; },
    match: function (pattern, consume, caseInsensitive) {
      if (typeof pattern == "string") {
        var cased = function (str) { return caseInsensitive ? str.toLowerCase() : str; };
        var substr = this.string.substr(this.pos, pattern.length);
        if (cased(substr) == cased(pattern)) {
          if (consume !== false) this.pos += pattern.length;
          return true;
        }
      } else {
        // vim.js reads an ex command name as \w+; Vim's own commands are
        // letters, so :m0, :t0 and :d2 are :m 0, :t 0 and :d 2.
        var match = this.string.slice(this.pos).match(pattern);
        if (match && pattern.source == exNamePattern.source) {
          var short = numericArgCommand.exec(match[0]);
          if (short) match = this.string.slice(this.pos).match(new RegExp("^(" + short[1] + ")"));
        }
        if (match && match.index > 0) return null;
        if (match && consume !== false) this.pos += match[0].length;
        return match;
      }
    },
    current: function () { return this.string.slice(this.start, this.pos); }
  };

  // ---------------------------------------------------------------------------
  // Document model: an array of lines with a lazily built offset index.
  // ---------------------------------------------------------------------------

  function Doc(text) { this.setText(text); }
  Doc.prototype.setText = function (text) {
    this.lines = String(text).split("\n");
    this.invalidate();
  };
  Doc.prototype.invalidate = function () { this.starts = null; this.value = null; };
  Doc.prototype.index = function () {
    if (!this.starts) {
      var starts = new Array(this.lines.length), offset = 0;
      for (var i = 0; i < this.lines.length; i++) {
        starts[i] = offset;
        offset += this.lines[i].length + 1;
      }
      this.starts = starts;
      this.length = offset - 1;
      this.pivot = -1;
      this.pending = 0;
    }
    return this.starts;
  };
  // Offset where line `n` starts. Line starts after `pivot` are stored
  // `pending` too small: shifting them is deferred, so a run of edits moving
  // through the document (:%s, undoing it) costs O(lines) in total.
  Doc.prototype.lineStart = function (n) {
    var starts = this.index();
    return starts[n] + (n > this.pivot ? this.pending : 0);
  };
  Doc.prototype.getLength = function () { this.index(); return this.length; };
  Doc.prototype.toString = function () {
    if (this.value == null) this.value = this.lines.join("\n");
    return this.value;
  };
  Doc.prototype.indexFromPos = function (pos) {
    var line = pos.line, ch = pos.ch;
    if (line < 0) { line = 0; ch = 0; }
    if (line >= this.lines.length) { line = this.lines.length - 1; ch = Infinity; }
    return this.lineStart(line) + clamp(ch || 0, 0, this.lines[line].length);
  };
  Doc.prototype.posFromIndex = function (offset) {
    var starts = this.index(), pivot = this.pivot, pending = this.pending;
    offset = clamp(offset, 0, this.length);
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (starts[mid] + (mid > pivot ? pending : 0) <= offset) lo = mid; else hi = mid - 1;
    }
    return new Pos(lo, offset - this.lineStart(lo));
  };
  Doc.prototype.slice = function (from, to) {
    if (to <= from) return "";
    var a = this.posFromIndex(from), b = this.posFromIndex(to);
    if (a.line === b.line) return this.lines[a.line].slice(a.ch, b.ch);
    var parts = [this.lines[a.line].slice(a.ch)];
    for (var l = a.line + 1; l < b.line; l++) parts.push(this.lines[l]);
    parts.push(this.lines[b.line].slice(0, b.ch));
    return parts.join("\n");
  };
  Doc.prototype.replace = function (from, to, text) {
    var a = this.posFromIndex(from), b = this.posFromIndex(to);
    var inserted = text.split("\n");
    inserted[0] = this.lines[a.line].slice(0, a.ch) + inserted[0];
    inserted[inserted.length - 1] += this.lines[b.line].slice(b.ch);
    if (a.line === b.line && inserted.length === 1) {
      this.lines[a.line] = inserted[0];
      if (this.starts) {
        var delta = text.length - (to - from), line = a.line, st = this.starts, j;
        if (this.pending === 0) {
          this.pivot = line;
          this.pending = delta;
        } else if (line >= this.pivot) {
          for (j = this.pivot + 1; j <= line; j++) st[j] += this.pending;
          this.pivot = line;
          this.pending += delta;
        } else {
          // Move the pivot down: lines in (line, pivot] are exact now and become implicit.
          for (j = line + 1; j <= this.pivot; j++) st[j] -= this.pending;
          this.pivot = line;
          this.pending += delta;
        }
        this.length += delta;
      }
      this.value = null;
      return;
    }
    var st = this.starts, removedLines = b.line - a.line + 1, m = inserted.length;
    if (st && m <= 4096) {
      // Make starts up to b.line exact and those after it `pending` too small,
      // splice in the starts of the inserted lines, and defer the shift of the
      // rest: deleting lines one by one down a file (:g/x/d) stays O(lines)
      // in total instead of re-indexing the whole file after each one.
      var k;
      if (this.pending === 0) { /* every start is exact */ }
      else if (this.pivot < b.line) { for (k = this.pivot + 1; k <= b.line; k++) st[k] += this.pending; }
      else { for (k = b.line + 1; k <= this.pivot; k++) st[k] -= this.pending; }
      var fresh = new Array(m), offset = st[a.line];
      for (k = 0; k < m; k++) { fresh[k] = offset; offset += inserted[k].length + 1; }
      st.splice.apply(st, [a.line, removedLines].concat(fresh));
      this.lines.splice.apply(this.lines, [a.line, removedLines].concat(inserted));
      var delta = text.length - (to - from);
      this.pivot = a.line + m - 1;
      this.pending += delta;
      this.length += delta;
      this.value = null;
      return;
    }
    this.lines = this.lines.slice(0, a.line).concat(inserted, this.lines.slice(b.line + 1));
    this.invalidate();
  };

  // ---------------------------------------------------------------------------
  // Undo history. One group per vim command; a whole insert session (including
  // the command that started it, e.g. `cw`) is a single group, as in Vim.
  // ---------------------------------------------------------------------------

  function History() { this.done = []; this.undone = []; this.current = null; this.suppressed = 0; }
  History.prototype.record = function (from, removed, inserted, selBefore) {
    if (this.suppressed) return;
    if (!this.current) {
      this.current = { changes: [], selBefore: selBefore };
      this.done.push(this.current);
      if (this.done.length > 1000) this.done.shift();
    }
    this.current.changes.push({ from: from, removed: removed, inserted: inserted });
    this.undone.length = 0;
  };
  History.prototype.close = function () { this.current = null; };
  History.prototype.clear = function () { this.done = []; this.undone = []; this.current = null; };

  // ---------------------------------------------------------------------------
  // Editor: the CodeMirror 5 interface vim.js is written against.
  // ---------------------------------------------------------------------------

  function Marker(cm, offset, assoc) {
    this.cm = cm;
    this.id = cm.$mid++;
    this.offset = offset;
    this.assoc = assoc;
    cm.marks[this.id] = this;
  }
  Marker.prototype.clear = function () { delete this.cm.marks[this.id]; };
  Marker.prototype.find = function () {
    if (this.offset == null) return null;
    return this.cm.posFromIndex(this.offset);
  };

  var HEADLESS_LINE_HEIGHT = 16;
  var HEADLESS_CHAR_WIDTH = 8;

  function CodeMirror(host, text, options) {
    this.host = host;
    this.doc = new Doc(text == null ? "" : text);
    this.sel = { ranges: [{ anchor: 0, head: 0 }], primary: 0 };
    this.state = {};
    this.marks = Object.create(null);
    this.$mid = 0;
    this.curOp = null;
    this.options = {
      tabSize: 4, indentUnit: 4, indentWithTabs: false, readOnly: false,
      lineComment: null, lineWrapping: false,
      viewportWidth: 800, viewportHeight: 30 * HEADLESS_LINE_HEIGHT
    };
    if (options) for (var k in options) this.options[k] = options[k];
    this._handlers = {};
    this.history = new History();
    this.$lastChangeEndOffset = 0;
    this.$lineHandles = null;
    this.$selDirty = false;
    this.$mode = "normal";
    this.$subMode = "";
    this.virtualSelection = null;
    this.headlessScroll = { left: 0, top: 0 };
    this.$folds = [];
    this.$foldCache = null;
    this.$foldDirty = false;
    this.$sentFolds = "";
    this.inputField = new VNode("textarea");
    this.wrapper = new VNode("div");
    this.dialog = null;
    this.banner = null;
    this.notification = null;
    this.searchQuery = null;
  }

  // ---- statics -------------------------------------------------------------

  CodeMirror.isMac = runtime.platform === "MacIntel" || runtime.platform === "iPhone";
  CodeMirror.Pos = Pos;
  CodeMirror.StringStream = StringStream;
  CodeMirror.on = on;
  CodeMirror.off = off;
  CodeMirror.signal = signal;
  CodeMirror.isWordChar = function (ch) { return wordChar.test(ch); };
  CodeMirror.addClass = function () {};
  CodeMirror.rmClass = function () {};
  CodeMirror.e_preventDefault = function (e) { if (e && e.preventDefault) e.preventDefault(); };
  CodeMirror.e_stop = function (e) {
    if (!e) return;
    if (e.stopPropagation) e.stopPropagation();
    if (e.preventDefault) e.preventDefault();
  };
  CodeMirror.findMatchingTag = function () { return null; };
  CodeMirror.findEnclosingTag = function (cm, pos) {
    var text = cm.doc.toString(), offset = cm.indexFromPos(pos);
    if (text.charAt(offset) == "<") offset++;
    var tagRe = /<(\/?)([A-Za-z][\w:.-]*)(?:\s[^<>]*?)?(\/?)>/g, stack = [], best = null, m;
    while ((m = tagRe.exec(text))) {
      var tag = { name: m[2], from: m.index, to: m.index + m[0].length };
      if (m[3]) continue; // self-closing
      if (!m[1]) { stack.push(tag); continue; }
      for (var i = stack.length - 1; i >= 0; i--) {
        if (stack[i].name !== tag.name) continue;
        var open = stack[i];
        stack.length = i;
        if (open.from < offset && offset < tag.to && (!best || open.from >= best.open.from)) best = { open: open, close: tag };
        break;
      }
      if (best && tag.from > offset && !stack.some(function (t) { return t.from < offset; })) break;
    }
    if (!best) return undefined;
    function range(t) { return { from: cm.posFromIndex(t.from), to: cm.posFromIndex(t.to), tag: t.name }; }
    return { open: range(best.open), close: range(best.close) };
  };
  CodeMirror.keyName = undefined;

  CodeMirror.commands = {
    undo: function (cm) { cm.undo(); },
    redo: function (cm) { cm.redo(); },
    cursorCharLeft: function (cm) { cm.moveH(-1, "char"); },
    newlineAndIndent: function (cm) {
      // At the end of a closed fold's header (`o` on a fold), open the line after the fold.
      if (cm.$folds.length) cm.sel.ranges.forEach(function (r) {
        if (r.anchor != r.head) return;
        var p = cm.doc.posFromIndex(r.head), end = cm.$foldEnd(p.line);
        if (end > p.line && p.ch == cm.getLine(p.line).length)
          r.anchor = r.head = cm.indexFromPos(new Pos(end, cm.getLine(end).length));
      });
      // As Vim with 'autoindent': the new line gets the indent of this one,
      // the white space the cursor was on goes, and an indent nothing was
      // typed after (<CR><CR>, o<Esc>) is removed.
      var indents = [], auto = cm.$autoIndent;
      cm.sel.ranges.forEach(function (r, i) {
        var p = cm.doc.posFromIndex(Math.min(r.anchor, r.head)), text = cm.getLine(p.line);
        indents[i] = /^[ \t]*/.exec(text)[0].slice(0, p.ch);
        if (r.anchor != r.head) return;
        r.head += /^[ \t]*/.exec(text.slice(p.ch))[0].length;
        if (auto && auto.line == p.line && text == auto.text && p.ch == text.length) r.anchor -= p.ch;
      });
      var newLines = [];
      cm.$replaceRanges(function (from, to, i) {
        newLines.push(indents[i]);
        return "\n" + indents[i];
      }, "end");
      var cur = cm.getCursor();
      cm.$autoIndent = newLines.length == 1 && newLines[0] ? { line: cur.line, text: newLines[0] } : null;
    },
    indentAuto: function (cm) { cm.indentAuto(); },
    toggleLineComment: function (cm) { cm.toggleLineComment(); },
    newlineAndIndentContinueComment: undefined,
    save: function (cm) { cm.$host().event("save", ""); }
  };

  // Keys vim.js sends back to the editor while replaying insert-mode mappings.
  CodeMirror.keys = {
    Left: function (cm) { cm.$moveCursors(-1); },
    Right: function (cm) { cm.$moveCursors(1); },
    Up: function (cm) { cm.setCursor(cm.findPosV(cm.getCursor(), -1, "line")); },
    Down: function (cm) { cm.setCursor(cm.findPosV(cm.getCursor(), 1, "line")); },
    Backspace: function (cm) { cm.$deleteChar(-1); },
    Delete: function (cm) { cm.$deleteChar(1); }
  };
  CodeMirror.lookupKey = function (key, map, handle) {
    var result = CodeMirror.keys[key];
    if (!result && /^Arrow/.test(key)) result = CodeMirror.keys[key.slice(5)];
    if (result) handle(result);
  };

  var proto = CodeMirror.prototype;

  // ---- events --------------------------------------------------------------

  proto.on = function (type, f) { on(this, type, f); };
  proto.off = function (type, f) { off(this, type, f); };
  proto.signal = function () { signal.apply(null, [this].concat(Array.prototype.slice.call(arguments))); };

  // ---- positions -------------------------------------------------------------

  proto.indexFromPos = function (pos) { return this.doc.indexFromPos(pos); };
  proto.posFromIndex = function (offset) { return this.doc.posFromIndex(offset); };
  proto.firstLine = function () { return 0; };
  proto.lastLine = function () { return this.doc.lines.length - 1; };
  proto.lineCount = function () { return this.doc.lines.length; };
  proto.getLine = function (row) {
    if (row < 0 || row >= this.doc.lines.length) return "";
    return this.doc.lines[row];
  };
  proto.clipPos = function (p) {
    var line = p.line, ch = p.ch;
    if (line < 0) { line = 0; ch = 0; }
    if (line >= this.doc.lines.length) { line = this.doc.lines.length - 1; ch = Number.MAX_VALUE; }
    return new Pos(line, clamp(ch || 0, 0, this.doc.lines[line].length));
  };
  proto.getValue = function () { return this.doc.toString(); };
  proto.getRange = function (s, e) {
    return this.doc.slice(this.indexFromPos(s), this.indexFromPos(e));
  };

  // ---- selection -------------------------------------------------------------

  proto.$setSel = function (ranges, primary, fromHost) {
    var len = this.doc.getLength();
    this.sel = {
      ranges: ranges.map(function (r) {
        return { anchor: clamp(r.anchor, 0, len), head: clamp(r.head, 0, len) };
      }),
      primary: clamp(primary || 0, 0, ranges.length - 1)
    };
    this.onSelectionChange();
    if (!fromHost) this.$selDirty = true;
  };
  proto.$primary = function () { return this.sel.ranges[this.sel.primary]; };

  proto.setCursor = function (line, ch) {
    if (typeof line === "object") { ch = line.ch; line = line.line; }
    var offset = this.indexFromPos({ line: line, ch: ch || 0 });
    var outsideOperation = !this.curOp;
    this.$setSel([{ anchor: offset, head: offset }], 0);
    if (this.curOp && !this.curOp.isVimOp) this.onBeforeEndOperation();
    if (outsideOperation) this.scrollIntoView();
  };
  proto.getCursor = function (p) {
    var r = this.$primary();
    var offset = p == "head" || !p ? r.head
      : p == "anchor" ? r.anchor
      : p == "start" ? Math.min(r.anchor, r.head)
      : p == "end" ? Math.max(r.anchor, r.head)
      : null;
    if (offset == null) throw new Error("Invalid cursor type");
    return this.posFromIndex(offset);
  };
  proto.listSelections = function () {
    var cm = this;
    return this.sel.ranges.map(function (r) {
      return { anchor: cm.posFromIndex(r.anchor), head: cm.posFromIndex(r.head) };
    });
  };
  proto.setSelections = function (ranges, primIndex) {
    var cm = this;
    if (this.$folds.length && this.state.vim && this.state.vim.visualLine) this.$selectWholeFolds(ranges);
    this.$setSel(ranges.map(function (x) {
      return { anchor: cm.indexFromPos(x.anchor), head: cm.indexFromPos(x.head) };
    }), primIndex);
    this.$afterDispatch();
  };
  proto.setSelection = function (anchor, head, options) {
    this.setSelections([{ anchor: anchor, head: head || anchor }], 0);
    if (options && options.origin == "*mouse") this.onBeforeEndOperation();
  };
  proto.getSelection = function () { return this.getSelections().join("\n"); };
  proto.getSelections = function () {
    var doc = this.doc;
    return this.sel.ranges.map(function (r) {
      return doc.slice(Math.min(r.anchor, r.head), Math.max(r.anchor, r.head));
    });
  };
  proto.somethingSelected = function () {
    return this.sel.ranges.some(function (r) { return r.anchor !== r.head; });
  };
  proto.$moveCursors = function (delta) {
    var len = this.doc.getLength();
    this.$setSel(this.sel.ranges.map(function (r) {
      var o = clamp(r.head + delta, 0, len);
      return { anchor: o, head: o };
    }), this.sel.primary);
    this.$afterDispatch();
  };
  proto.moveH = function (increment, unit) {
    if (unit == "char") {
      var cur = this.getCursor();
      this.setCursor(cur.line, cur.ch + increment);
    }
  };

  // ---- changes ---------------------------------------------------------------

  // Applies one replacement. `fromHost` marks edits that already happened in
  // the native view (typing, paste), so they are not sent back.
  proto.$applyChange = function (from, to, text, fromHost, origin) {
    var len = this.doc.getLength();
    from = clamp(from, 0, len);
    to = clamp(to, from, len);
    if (from === to && !text) return;
    var removed = this.doc.slice(from, to);
    var selBefore = this.sel.ranges.map(function (r) { return { anchor: r.anchor, head: r.head }; });
    if (!this.history.suppressed) this.$noteLineChange(from, removed, text);
    if (this.$folds.length) this.$foldsBeforeChange(from, to);
    this.doc.replace(from, to, text);
    var n = text.length;

    this.sel.ranges.forEach(function (r) {
      r.anchor = mapPos(r.anchor, from, to, n, 1);
      r.head = mapPos(r.head, from, to, n, 1);
    });
    for (var id in this.marks) {
      var m = this.marks[id];
      if (m.offset != null) m.offset = mapPos(m.offset, from, to, n, m.assoc, "del");
    }
    if (this.$lineHandles) {
      this.$lineHandles.forEach(function (h) {
        if (h.index != null) h.index = mapPos(h.index, from, to, n, 1, "after");
      });
    }
    if (this.virtualSelection) {
      this.virtualSelection.ranges.forEach(function (r) {
        r.anchor = mapPos(r.anchor, from, to, n, 1);
        r.head = mapPos(r.head, from, to, n, 1);
      });
    }
    this.history.record(from, removed, text, selBefore);
    this.$lastChangeEndOffset = from + n;
    this.$layoutCache = null;

    var curOp = this.curOp = this.curOp || {};
    if (curOp.$changeStart == null || curOp.$changeStart > from) curOp.$changeStart = from;
    var change = { text: text.split("\n"), origin: origin };
    if (!curOp.lastChange) curOp.lastChange = curOp.change = change;
    else curOp.lastChange.next = curOp.lastChange = change;
    if (!curOp.changeHandlers)
      curOp.changeHandlers = this._handlers["change"] && this._handlers["change"].slice();

    if (curOp.$scroll) curOp.$scroll.offset = mapPos(curOp.$scroll.offset, from, to, n, 1);
    if (!fromHost) {
      this.$selDirty = true;
      this.$queueEdit(from, to, text, len);
    }
    if (this.searchQuery) this.$searchDirty = true;
  };

  // Many changes at once: `changes` is flat [from, to, text, ...] in the
  // coordinates of the text before all of them. The effect is that of
  // $applyChange on each in turn, shifted, but the document, selections,
  // marks, folds and the host are updated in one pass: re-indenting or
  // undoing 20,000 lines is one batch instead of 20,000 edits. Changes that
  // are not ascending and apart, or fewer than 64, go through $applyChange
  // one by one.
  proto.$applyChanges = function (changes, fromHost, origin) {
    if (!this.history.suppressed && changes.length > 3) this.$uLine = null;
    var len = this.doc.getLength(), froms = [], tos = [], texts = [], last = 0, k;
    for (k = 0; k < changes.length; k += 3) {
      var from = changes[k], to = changes[k + 1], text = changes[k + 2];
      if (from < last || to < from || to > len || (froms.length && from === froms[froms.length - 1])) {
        froms = null;
        break;
      }
      if (from === to && !text) continue;
      froms.push(from); tos.push(to); texts.push(text);
      last = to;
    }
    // A batch rebuilds the document's text and line index (O(length)); a
    // few changes are cheaper one by one.
    if (!froms || froms.length < 64) {
      for (k = 0, shift = 0; k < changes.length; k += 3) {
        this.$applyChange(changes[k] + shift, changes[k + 1] + shift, changes[k + 2], fromHost, origin);
        shift += changes[k + 2].length - (changes[k + 1] - changes[k]);
      }
      return;
    }
    var n = froms.length;

    if (this.$folds.length) this.$foldsBeforeChanges(froms, tos);
    var whole = this.doc.toString(), parts = [], shifts = new Array(n), lens = new Array(n), shift = 0;
    var selBefore = this.sel.ranges.map(function (r) { return { anchor: r.anchor, head: r.head }; });
    var curOp = this.curOp = this.curOp || {};
    if (!curOp.changeHandlers)
      curOp.changeHandlers = this._handlers["change"] && this._handlers["change"].slice();
    last = 0;
    for (k = 0; k < n; k++) {
      shifts[k] = shift;
      lens[k] = texts[k].length;
      parts.push(whole.slice(last, froms[k]), texts[k]);
      this.history.record(froms[k] + shift, whole.slice(froms[k], tos[k]), texts[k], selBefore);
      var change = { text: texts[k].split("\n"), origin: origin };
      if (!curOp.lastChange) curOp.lastChange = curOp.change = change;
      else curOp.lastChange.next = curOp.lastChange = change;
      shift += lens[k] - (tos[k] - froms[k]);
      last = tos[k];
    }
    parts.push(whole.slice(last));
    var value = parts.join("");
    this.doc.setText(value);
    this.doc.value = value;

    // Old offset -> new: through the last change that starts at or before it.
    function map(pos, assoc, mode) {
      if (pos == null) return pos;
      var lo = 0, hi = n - 1, i = -1;
      while (lo <= hi) {
        var mid = (lo + hi) >> 1;
        if (froms[mid] <= pos) { i = mid; lo = mid + 1; } else hi = mid - 1;
      }
      if (i < 0) return pos;
      var s = shifts[i];
      return mapPos(pos + s, froms[i] + s, tos[i] + s, lens[i], assoc, mode);
    }
    this.sel.ranges.forEach(function (r) { r.anchor = map(r.anchor, 1); r.head = map(r.head, 1); });
    for (var id in this.marks) {
      var mark = this.marks[id];
      if (mark.offset != null) mark.offset = map(mark.offset, mark.assoc, "del");
    }
    if (this.$lineHandles) {
      this.$lineHandles.forEach(function (h) { if (h.index != null) h.index = map(h.index, 1, "after"); });
    }
    if (this.virtualSelection) {
      this.virtualSelection.ranges.forEach(function (r) { r.anchor = map(r.anchor, 1); r.head = map(r.head, 1); });
    }
    this.$lastChangeEndOffset = froms[n - 1] + shifts[n - 1] + lens[n - 1];
    this.$layoutCache = null;
    if (curOp.$changeStart == null || curOp.$changeStart > froms[0]) curOp.$changeStart = froms[0];
    if (curOp.$scroll) curOp.$scroll.offset = map(curOp.$scroll.offset, 1);
    if (!fromHost) {
      this.$selDirty = true;
      this.$queueEdit(froms[0], tos[n - 1], value.slice(froms[0], tos[n - 1] + shift), len);
    }
    if (this.searchQuery) this.$searchDirty = true;
  };

  // ---- edits sent to the host ---------------------------------------------------------
  //
  // Edits are queued and sent in one `host.edits([from, to, text, ...])` call
  // when the operation ends, or earlier when the host is asked anything that
  // depends on its text (geometry, events). Offsets of each edit refer to the
  // text after the previous one. A large batch (e.g. :%s over a big file) is
  // sent as one replacement of the region that changed.
  proto.$queueEdit = function (from, to, text, lengthBefore) {
    var q = this.$edits;
    if (!q) q = this.$edits = { list: [], base: lengthBefore, lo: lengthBefore, tail: lengthBefore };
    q.list.push(from, to, text);
    if (from < q.lo) q.lo = from;
    if (lengthBefore - to < q.tail) q.tail = lengthBefore - to;
  };
  proto.$flushEdits = function () {
    var q = this.$edits;
    if (!q) return;
    this.$edits = null;
    var count = q.list.length / 3, oldEnd = q.base - q.tail;
    if (count > 1 && (count > 16 || oldEnd - q.lo <= 4096)) {
      var newEnd = this.doc.getLength() - q.tail;
      this.host.edits([q.lo, oldEnd, this.doc.slice(q.lo, newEnd)]);
    } else {
      this.host.edits(q.list);
    }
  };
  proto.$host = function () {
    this.$flushEdits();
    return this.host;
  };

  // Replaces every selection range with text(from, to, index). `place` is
  // "end" (cursor after the text), "around" (select it) or "start".
  proto.$replaceRanges = function (textFor, place, origin) {
    var ranges = this.sel.ranges.map(function (r, i) {
      return { from: Math.min(r.anchor, r.head), to: Math.max(r.anchor, r.head), i: i };
    }).sort(function (a, b) { return a.from - b.from; });
    var result = new Array(ranges.length), shift = 0;
    for (var k = 0; k < ranges.length; k++) {
      var r = ranges[k];
      var text = textFor(r.from + shift, r.to + shift, r.i);
      this.$applyChange(r.from + shift, r.to + shift, text, false, origin);
      var start = r.from + shift, end = start + text.length;
      result[r.i] = place == "around" ? { anchor: start, head: end }
        : place == "start" ? { anchor: start, head: start }
        : { anchor: end, head: end };
      shift += text.length - (r.to - r.from);
    }
    this.$setSel(result, this.sel.primary);
    this.$afterDispatch();
  };

  proto.replaceRange = function (text, s, e, origin) {
    if (!e) e = s;
    var a = this.indexFromPos(s), b = this.indexFromPos(e);
    this.$applyChange(Math.min(a, b), Math.max(a, b), text, false, origin);
    this.$afterDispatch();
  };
  proto.replaceSelection = function (text, select) {
    this.$replaceRanges(function () { return text; }, select || "end");
  };
  proto.replaceSelections = function (replacements) {
    var ranges = this.sel.ranges.map(function (r, i) {
      return { from: Math.min(r.anchor, r.head), to: Math.max(r.anchor, r.head), i: i };
    }).sort(function (a, b) { return b.from - a.from; });
    for (var k = 0; k < ranges.length; k++) {
      this.$applyChange(ranges[k].from, ranges[k].to, replacements[ranges[k].i] || "", false);
    }
    this.$afterDispatch();
  };
  proto.overWriteSelection = function (text) {
    var doc = this.doc, len = doc.getLength();
    // Replace mode remembers what it overwrote, so <BS> can restore it.
    if (this.sel.ranges.length == 1 && this.sel.ranges[0].anchor === this.sel.ranges[0].head) {
      var at = this.sel.ranges[0].head, old = at < len ? doc.slice(at, at + 1) : "";
      if (old == "\n") old = "";
      (this.$replaced = this.$replaced || []).push({ at: at, length: text.length, original: old });
    }
    this.$setSel(this.sel.ranges.map(function (r) {
      if (r.anchor === r.head && r.head < len) {
        var ch = doc.slice(r.head, r.head + 1);
        if (ch && ch !== "\n") return { anchor: r.head, head: r.head + 1 };
      }
      return r;
    }), this.sel.primary);
    this.replaceSelection(text);
  };
  proto.$deleteChar = function (dir) {
    if (this.somethingSelected()) { this.replaceSelection(""); return; }
    var len = this.doc.getLength();
    var ranges = this.sel.ranges.map(function (r) { return r.head; }).sort(function (a, b) { return b - a; });
    for (var i = 0; i < ranges.length; i++) {
      var h = ranges[i];
      if (dir < 0 && h > 0) this.$applyChange(h - 1, h, "", false);
      if (dir > 0 && h < len) this.$applyChange(h, h + 1, "", false);
    }
    this.$afterDispatch();
  };
  proto.setValue = function (text) {
    this.$clearFolds();
    this.$layoutCache = null;
    this.doc.setText(text);
    this.history.clear();
    this.marks = Object.create(null);
    this.$setSel([{ anchor: 0, head: 0 }], 0, true);
    this.curOp = null;
  };

  // ---- undo ------------------------------------------------------------------

  // U undoes the changes made to the last changed line. A change within one
  // line remembers that line as it was before its first change (and the
  // cursor column then); a change across lines forgets it. Undo (u) does not
  // touch it.
  proto.$noteLineChange = function (from, removed, text) {
    if (this.$undoingLine) return;
    if (removed.indexOf("\n") >= 0 || text.indexOf("\n") >= 0) { this.$uLine = null; return; }
    var line = this.doc.posFromIndex(from).line;
    if (this.$uLine && this.$uLine.line == line) return;
    var cursor = this.getCursor("start");
    this.$uLine = { line: line, text: this.getLine(line), col: cursor.line == line ? cursor.ch : 0 };
  };
  proto.$undoLine = function () {
    var u = this.$uLine;
    if (!u || u.line > this.lastLine()) return;
    var cursor = this.getCursor(), current = this.getLine(u.line), col = u.col;
    this.$undoingLine = true;
    try { this.replaceRange(u.text, new Pos(u.line, 0), new Pos(u.line, current.length)); }
    finally { this.$undoingLine = false; }
    this.$uLine = { line: u.line, text: current, col: cursor.line == u.line ? cursor.ch : col };
    this.setCursor(new Pos(u.line, Math.max(0, Math.min(col, this.getLine(u.line).length - 1))));
  };

  proto.$runHistory = function (from, to, invert) {
    var history = this.history;
    history.close();
    var group = from.pop();
    if (!group) return;
    history.suppressed++;
    var start = Infinity;
    try {
      var changes = group.changes, batch = changes.length >= 64 ? this.$historyBatch(changes, invert) : null;
      if (batch) {
        this.$applyChanges(batch, false);
        start = batch[0];
      } else if (invert) {
        for (var i = changes.length - 1; i >= 0; i--) {
          var c = changes[i];
          this.$applyChange(c.from, c.from + c.inserted.length, c.removed, false);
          start = Math.min(start, c.from);
        }
      } else {
        for (var j = 0; j < changes.length; j++) {
          var d = changes[j];
          this.$applyChange(d.from, d.from + d.removed.length, d.inserted, false);
          start = Math.min(start, d.from);
        }
      }
    } finally {
      history.suppressed--;
    }
    to.push(group);
    if (start !== Infinity) this.$setSel([{ anchor: start, head: start }], 0);
    this.$afterDispatch();
  };
  // A history group as one $applyChanges batch (offsets before the replay),
  // or null when its changes are not ascending and apart.
  proto.$historyBatch = function (changes, invert) {
    var flat = new Array(changes.length * 3), shift = 0, end = -1;
    for (var i = 0; i < changes.length; i++) {
      var c = changes[i], from = invert ? c.from : c.from - shift;
      if (from < end || (i && from <= flat[3 * (i - 1)])) return null;
      var removedLength = invert ? c.inserted.length : c.removed.length;
      flat[3 * i] = from;
      flat[3 * i + 1] = from + removedLength;
      flat[3 * i + 2] = invert ? c.removed : c.inserted;
      end = from + removedLength;
      shift += c.inserted.length - c.removed.length;
    }
    return flat;
  };
  proto.undo = function () { this.$undoing = true; this.$runHistory(this.history.done, this.history.undone, true); };
  proto.redo = function () { this.$undoing = true; this.$runHistory(this.history.undone, this.history.done, false); };

  // ---- operations ------------------------------------------------------------

  proto.onSelectionChange = function () {
    var curOp = this.curOp = this.curOp || {};
    if (!curOp.cursorActivityHandlers)
      curOp.cursorActivityHandlers = this._handlers["cursorActivity"] && this._handlers["cursorActivity"].slice();
    curOp.cursorActivity = true;
  };
  // Mirrors CodeMirror 6, where every dispatch outside a vim operation ends
  // the pending operation immediately.
  proto.$afterDispatch = function () {
    if (this.curOp && !this.curOp.isVimOp && !this.$ending) this.onBeforeEndOperation();
  };
  proto.operation = function (fn) {
    if (!this.curOp) this.curOp = { $d: 0 };
    this.curOp.$d = (this.curOp.$d || 0) + 1;
    try {
      var result = fn();
    } finally {
      if (this.curOp) {
        this.curOp.$d--;
        if (!this.curOp.$d) this.onBeforeEndOperation();
      }
    }
    return result;
  };
  proto.onBeforeEndOperation = function () {
    var op = this.curOp, scroll = false, pendingScroll = op && op.$scroll;
    this.$ending = true;
    if (this.$folds.length) this.$revealCursor();
    try {
      if (op) {
        if (op.change) signalTo(op.changeHandlers, this, op.change);
        if (op.cursorActivity) {
          signalTo(op.cursorActivityHandlers, this, null);
          if (op.isVimOp) scroll = true;
        }
        this.curOp = null;
      }
    } finally {
      this.$ending = false;
    }
    if (this.$keyDepth) {
      // Inside one key vim.js can run thousands of operations (:normal over
      // every line, a macro, a count). The host gets their sum when the key
      // ends (see handleKeyEvent): edits, selection, status and one scroll.
      // Questions to the host (geometry) still send pending edits first.
      if (pendingScroll || scroll) this.$keyScroll = { pending: pendingScroll, cursor: scroll };
      return;
    }
    this.$flush();
    if (pendingScroll) this.$scrollNow(pendingScroll.offset, pendingScroll.margin);
    if (scroll) this.scrollIntoView();
  };
  proto.$flush = function () {
    this.$flushEdits();
    this.$sendFolds();
    if (this.$selDirty) {
      this.$selDirty = false;
      var flat = [];
      this.sel.ranges.forEach(function (r) { flat.push(r.anchor, r.head); });
      this.host.select(flat, this.sel.primary);
    }
    if (this.$searchDirty) {
      this.$searchDirty = false;
      this.$host().event("highlight", this.searchQuery ? "changed" : "");
    }
    this.$emitState();
  };

  // ---- line handles & bookmarks ------------------------------------------------

  proto.getLineHandle = function (row) {
    if (!this.$lineHandles) this.$lineHandles = [];
    var handle = { row: row, index: this.indexFromPos(new Pos(row, 0)) };
    this.$lineHandles.push(handle);
    return handle;
  };
  proto.getLineNumber = function (handle) {
    if (!this.$lineHandles || handle.index == null) return null;
    var pos = this.posFromIndex(handle.index);
    return pos.ch == 0 ? pos.line : null;
  };
  proto.releaseLineHandles = function () { this.$lineHandles = null; };
  proto.setBookmark = function (cursor, options) {
    return new Marker(this, this.indexFromPos(cursor), options && options.insertLeft ? 1 : -1);
  };
  proto.getLastEditEnd = function () { return this.posFromIndex(this.$lastChangeEndOffset); };

  // ---- search ----------------------------------------------------------------

  // Iterates matches of `query` between `from` and `to` the way CodeMirror 6's
  // RegExpCursor does: line by line on text cut off at `to`, skipping an
  // empty match that touches the previous match. Patterns that can span
  // lines run over the flat text instead.
  function regExpCursor(cm, query, from, to) {
    var re = new RegExp(query.source, "gm" + (query.ignoreCase ? "i" : ""));
    var doc = cm.doc;
    var lastTo = -1, matchPos = from;
    if (/\\[sWDnr]|\n|\r|\[\^/.test(query.source)) {
      var flat = doc.toString().slice(0, to);
      return {
        next: function () {
          for (;;) {
            if (matchPos > flat.length) return null;
            re.lastIndex = matchPos;
            var m = re.exec(flat);
            if (!m) return null;
            var mf = m.index, mt = mf + m[0].length;
            matchPos = mt + (mf == mt ? 1 : 0);
            if (mf < mt || mf > lastTo) { lastTo = mt; return { from: mf, to: mt, match: m }; }
          }
        }
      };
    }

    var lineNo = doc.posFromIndex(from).line, lineStart, line;
    function loadLine() {
      lineStart = doc.lineStart(lineNo);
      line = doc.lines[lineNo];
      if (lineStart + line.length > to) line = line.slice(0, Math.max(0, to - lineStart));
    }
    loadLine();
    return {
      next: function () {
        for (;;) {
          var off = matchPos - lineStart, m = null;
          if (off <= line.length && matchPos <= to) { re.lastIndex = off; m = re.exec(line); }
          if (m) {
            var mf = lineStart + m.index, mt = mf + m[0].length;
            matchPos = mt + (mf == mt ? 1 : 0);
            if (mf == lineStart + line.length && lineNo + 1 < doc.lines.length) { lineNo++; loadLine(); }
            if (mf < mt || mf > lastTo) { lastTo = mt; return { from: mf, to: mt, match: m }; }
          } else if (lineStart + line.length < to && lineNo + 1 < doc.lines.length) {
            lineNo++;
            loadLine();
            matchPos = lineStart;
          } else {
            return null;
          }
        }
      }
    };
  }

  // Vim's case modifiers in a :s replacement (\u \l \U \L \e \E) travel
  // through vim.js as these private characters and apply here.
  var CASE_MARKS = { u: "\ue001", l: "\ue002", U: "\ue003", L: "\ue004", e: "\ue005", E: "\ue005" };
  function applyCaseMarks(text) {
    if (!/[\ue001-\ue005]/.test(text)) return text;
    var out = "", one = null, all = null;
    for (var i = 0; i < text.length; i++) {
      var c = text.charAt(i);
      if (c == "\ue001" || c == "\ue002") { one = c; continue; }
      if (c == "\ue003" || c == "\ue004") { all = c; one = null; continue; }
      if (c == "\ue005") { all = null; one = null; continue; }
      if (all) c = all == "\ue003" ? c.toUpperCase() : c.toLowerCase();
      if (one) { c = one == "\ue001" ? c.toUpperCase() : c.toLowerCase(); one = null; }
      out += c;
    }
    return out;
  }
  // A Vim :s replacement in the form vim.js (with nopcre) understands: & is
  // the match, \& a literal &, \r a line break, case modifiers as marks.
  function vimReplacement(text) {
    return text.replace(/\\(.)|&/g, function (m, c) {
      if (m == "&") return "\\0";
      if (c == "&") return "&";
      if (c == "r") return "\\n";
      if (CASE_MARKS[c]) return CASE_MARKS[c];
      return m;
    });
  }

  proto.getSearchCursor = function (query, pos) {
    var cm = this, last = null, lastResult = null, afterEmptyMatch = false;
    if (pos.ch == undefined) pos.ch = Number.MAX_VALUE;
    var firstOffset = cm.indexFromPos(pos);

    function nextMatch(from) {
      var length = cm.doc.getLength();
      if (from > length) return null;
      return regExpCursor(cm, query, from, length).next();
    }
    var ChunkSize = 10000;
    function prevMatchInRange(from, to) {
      for (var size = 1; ; size++) {
        var start = Math.max(from, to - size * ChunkSize);
        var cursor = regExpCursor(cm, query, start, to), range = null, r;
        while ((r = cursor.next())) range = r;
        if (range && (start == from || range.from > start + 10)) return range;
        if (start == from) return null;
      }
    }
    return {
      findNext: function () { return this.find(false); },
      findPrevious: function () { return this.find(true); },
      find: function (back) {
        if (back) {
          var endAt = last ? (afterEmptyMatch ? last.to - 1 : last.from) : firstOffset;
          last = endAt < 0 ? null : prevMatchInRange(0, endAt);
        } else {
          var startFrom = last ? (afterEmptyMatch ? last.to + 1 : last.to) : firstOffset;
          last = nextMatch(startFrom);
        }
        lastResult = last && { from: cm.posFromIndex(last.from), to: cm.posFromIndex(last.to), match: last.match };
        afterEmptyMatch = last ? last.from == last.to : false;
        return last && last.match;
      },
      from: function () { return lastResult && lastResult.from; },
      to: function () { return lastResult && lastResult.to; },
      replace: function (text) {
        if (!last) return;
        text = applyCaseMarks(text);
        cm.$applyChange(last.from, last.to, text, false);
        cm.$lastReplaceEnd = last.from + text.length;
        cm.$afterDispatch();
        last.to = last.from + text.length;
        if (lastResult) lastResult.to = cm.posFromIndex(last.to);
      },
      get match() { return lastResult && lastResult.match; }
    };
  };

  proto.addOverlay = function (overlay) {
    var query = overlay && overlay.query;
    if (!(query instanceof RegExp)) return;
    this.searchQuery = query;
    this.$searchDirty = true;
    if (!this.curOp) this.$flush();
    return overlay;
  };
  proto.removeOverlay = function () {
    if (!this.searchQuery) return;
    this.searchQuery = null;
    this.$searchDirty = true;
    if (!this.curOp) this.$flush();
  };
  // Flat [from, to, from, to, ...] list of search matches inside [from, to).
  proto.matchRanges = function (from, to, limit) {
    if (!this.searchQuery) return [];
    var length = this.doc.getLength();
    var end = to == null || to < 0 ? length : Math.min(to, length);
    var cursor = regExpCursor(this, this.searchQuery, Math.max(0, from || 0), end), out = [], r;
    limit = limit || 10000;
    while ((r = cursor.next()) && out.length < limit * 2) {
      if (r.to > r.from) out.push(r.from, r.to);
    }
    return out;
  };

  // ---- brackets ----------------------------------------------------------------

  var matching = { "(": ")>", ")": "(<", "[": "]>", "]": "[<", "{": "}>", "}": "{<", "<": ">>", ">": "<<" };

  proto.scanForBracket = function (where, dir, style, config) {
    var maxScanLen = (config && config.maxScanLineLength) || 10000;
    var maxScanLines = (config && config.maxScanLines) || 1000;
    var stack = [];
    var re = (config && config.bracketRegex) || /[(){}[\]]/;
    var lineEnd = dir > 0 ? Math.min(where.line + maxScanLines, this.lastLine() + 1)
      : Math.max(this.firstLine() - 1, where.line - maxScanLines);
    for (var lineNo = where.line; lineNo != lineEnd; lineNo += dir) {
      var line = this.getLine(lineNo);
      if (!line) continue;
      var pos = dir > 0 ? 0 : line.length - 1, end = dir > 0 ? line.length : -1;
      if (line.length > maxScanLen) continue;
      if (lineNo == where.line) pos = where.ch - (dir < 0 ? 1 : 0);
      for (; pos != end; pos += dir) {
        var ch = line.charAt(pos);
        if (re.test(ch) && (style === undefined || this.getTokenTypeAt(new Pos(lineNo, pos + 1)) === style)) {
          var match = matching[ch];
          if (match && (match.charAt(1) == ">") == (dir > 0)) stack.push(ch);
          else if (!stack.length) return { pos: new Pos(lineNo, pos), ch: ch };
          else stack.pop();
        }
      }
    }
    return lineNo - dir == (dir > 0 ? this.lastLine() : this.firstLine()) ? false : null;
  };
  proto.findMatchingBracket = function (pos) {
    var ch = this.getLine(pos.line).charAt(pos.ch);
    var match = matching[ch];
    if (!match || ch == "<" || ch == ">") return { to: undefined };
    var dir = match.charAt(1) == ">" ? 1 : -1;
    var other = match.charAt(0);
    var pair = dir > 0 ? ch + other : other + ch;
    var re = new RegExp("[" + pair.replace(/[\]\[]/g, "\\$&") + "]");
    // Like CodeMirror: only brackets in the same kind of token (code, string, comment) pair up.
    var style = this.getTokenTypeAt(new Pos(pos.line, pos.ch + 1));
    var found = this.scanForBracket(new Pos(pos.line, pos.ch + (dir > 0 ? 1 : 0)), dir, style, { bracketRegex: re });
    return { to: found && found.pos ? found.pos : undefined };
  };

  // ---- indentation & formatting -------------------------------------------------

  function countColumn(string, tabSize) {
    var col = 0;
    for (var i = 0; i < string.length; i++) col = string.charAt(i) == "\t" ? col + tabSize - (col % tabSize) : col + 1;
    return col;
  }
  proto.$makeIndent = function (col) {
    if (!this.getOption("indentWithTabs")) return repeatString(" ", col);
    var tab = this.getOption("tabSize");
    return repeatString("\t", Math.floor(col / tab)) + repeatString(" ", col % tab);
  };
  proto.indentLine = function (n, more) {
    var text = this.getLine(n);
    var current = /^[ \t]*/.exec(text)[0];
    var col = countColumn(current, this.getOption("tabSize"));
    var unit = this.getOption("indentUnit");
    var next = more ? col + unit : Math.max(0, col - unit);
    var indent = this.$makeIndent(next);
    if (indent !== current) this.replaceRange(indent, new Pos(n, 0), new Pos(n, current.length));
  };
  proto.$selectedLines = function () {
    var cm = this, seen = {}, lines = [];
    this.sel.ranges.forEach(function (r) {
      var a = cm.posFromIndex(Math.min(r.anchor, r.head)), b = cm.posFromIndex(Math.max(r.anchor, r.head));
      var last = b.line > a.line && b.ch == 0 ? b.line - 1 : b.line;
      for (var l = a.line; l <= last; l++) if (!seen[l]) { seen[l] = true; lines.push(l); }
    });
    return lines;
  };
  // Indentation for line `n` from the previous non-blank line: one more unit
  // after an unclosed bracket, one less before a closing bracket.
  proto.$autoIndentColumn = function (n) {
    var unit = this.getOption("indentUnit"), col = 0, prev = n - 1;
    while (prev >= 0 && !/\S/.test(this.getLine(prev))) prev--;
    if (prev >= 0) {
      var text = this.getLine(prev), depth = 0;
      col = countColumn(/^[ \t]*/.exec(text)[0], this.getOption("tabSize"));
      for (var i = 0; i < text.length; i++) {
        var c = text.charAt(i);
        if (c == "(" || c == "[" || c == "{") depth++;
        else if ((c == ")" || c == "]" || c == "}") && depth > 0) depth--;
      }
      if (depth > 0) col += unit;
    }
    if (/^[ \t]*[)\]}]/.test(this.getLine(n))) col = Math.max(0, col - unit);
    return col;
  };
  // Re-indents the selected lines: mode 0 is `<`, 1 is `>`, 2 is `=`.
  // The new columns come from $indentPlan; the lines change in one batch.
  proto.$reindent = function (mode) {
    var cm = this, lines = this.$selectedLines().sort(function (a, b) { return a - b; });
    var plan = this.$indentPlan(lines, mode), indents = {}, changes = [];
    for (var i = 0; i < lines.length; i++) {
      var col = plan[2 * i + 1], length = plan[2 * i];
      if (col < 0 || length < 0) continue;
      var indent = indents[col];
      if (indent == null) indent = indents[col] = this.$makeIndent(col);
      var text = this.doc.lines[lines[i]];
      if (length === indent.length && text.slice(0, length) === indent) continue;
      var start = this.doc.lineStart(lines[i]);
      changes.push(start, start + length, indent);
    }
    if (!changes.length) return;
    this.operation(function () {
      cm.$applyChanges(changes, false);
      cm.$afterDispatch();
    });
  };
  // [length of the leading spaces and tabs, new column, ...] per line of
  // `lines` (ascending); column -1 leaves a line alone (blank lines for `=`).
  // Many lines go to the host's native kernel (VimIndentKernel in Swift).
  proto.$indentPlan = function (lines, mode) {
    var tab = this.getOption("tabSize"), unit = this.getOption("indentUnit");
    if (lines.length >= 32 && this.host.indentPlan) {
      var plan = this.host.indentPlan(this.doc.toString(), new Int32Array(lines), mode, tab, unit);
      if (plan && plan.length === lines.length * 2) return plan;
    }
    return this.$indentPlanJS(lines, mode, tab, unit);
  };
  // The same plan in JavaScript; `=` follows $autoIndentColumn, seeing the
  // lines above as already re-indented.
  proto.$indentPlanJS = function (lines, mode, tab, unit) {
    var out = new Int32Array(lines.length * 2), cols = {};
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i], text = this.getLine(l), prefix = /^[ \t]*/.exec(text)[0], col = -1;
      if (mode < 2) {
        var current = countColumn(prefix, tab);
        col = mode ? current + unit : Math.max(0, current - unit);
      } else if (/\S/.test(text)) {
        col = 0;
        var prev = l - 1;
        while (prev >= 0 && !/\S/.test(this.getLine(prev))) prev--;
        if (prev >= 0) {
          var above = this.getLine(prev), depth = 0;
          col = prev in cols ? cols[prev] : countColumn(/^[ \t]*/.exec(above)[0], tab);
          for (var j = 0; j < above.length; j++) {
            var c = above.charAt(j);
            if (c == "(" || c == "[" || c == "{") depth++;
            else if ((c == ")" || c == "]" || c == "}") && depth > 0) depth--;
          }
          if (depth > 0) col += unit;
        }
        if (/^[ \t]*[)\]}]/.test(text)) col = Math.max(0, col - unit);
        cols[l] = col;
      }
      out[2 * i] = prefix.length;
      out[2 * i + 1] = col;
    }
    return out;
  };
  // Re-indents the selected lines (Vim's `=`).
  proto.indentAuto = function () { this.$reindent(2); };
  proto.indentMore = function () { this.$reindent(1); };
  proto.indentLess = function () { this.$reindent(0); };
  proto.toggleLineComment = function () {
    var token = this.getOption("lineComment");
    if (!token) return;
    var cm = this, lines = this.$selectedLines();
    var all = lines.every(function (l) { return !/\S/.test(cm.getLine(l)) || cm.getLine(l).trim().indexOf(token) === 0; });
    this.operation(function () {
      lines.forEach(function (l) {
        var text = cm.getLine(l);
        if (!/\S/.test(text)) return;
        var indent = /^\s*/.exec(text)[0].length;
        if (all) {
          var len = token.length + (text.charAt(indent + token.length) === " " ? 1 : 0);
          cm.replaceRange("", new Pos(l, indent), new Pos(l, indent + len));
        } else {
          cm.replaceRange(token + " ", new Pos(l, indent));
        }
      });
    });
  };
  proto.hardWrap = function (options) {
    var cm = this;
    var max = options.column || cm.getOption("textwidth") || 80;
    var allowMerge = options.allowMerge != false;
    var row = Math.min(options.from, options.to);
    var endRow = Math.max(options.from, options.to);
    while (row <= endRow) {
      var line = cm.getLine(row);
      if (line.length > max) {
        var space = findSpace(line, max, 5);
        if (space) {
          var indentation = /^\s*/.exec(line)[0];
          cm.replaceRange("\n" + indentation, new Pos(row, space.start), new Pos(row, space.end));
        }
        endRow++;
      } else if (allowMerge && /\S/.test(line) && row != endRow) {
        var nextLine = cm.getLine(row + 1);
        if (nextLine && /\S/.test(nextLine)) {
          var trimmedLine = line.replace(/\s+$/, "");
          var trimmedNextLine = nextLine.replace(/^\s+/, "");
          var mergedLine = trimmedLine + " " + trimmedNextLine;
          var mergedSpace = findSpace(mergedLine, max, 5);
          if (mergedSpace && mergedSpace.start > trimmedLine.length || mergedLine.length < max) {
            cm.replaceRange(" ", new Pos(row, trimmedLine.length), new Pos(row + 1, nextLine.length - trimmedNextLine.length));
            row--;
            endRow--;
          } else if (trimmedLine.length < line.length) {
            cm.replaceRange("", new Pos(row, trimmedLine.length), new Pos(row, line.length));
          }
        }
      }
      row++;
    }
    return row;

    function findSpace(line, max, min) {
      if (line.length < max) return;
      var before = line.slice(0, max);
      var after = line.slice(max);
      var spaceAfter = /^(?:(\s+)|(\S+)(\s+))/.exec(after);
      var spaceBefore = /(?:(\s+)|(\s+)(\S+))$/.exec(before);
      var start = 0, end = 0;
      if (spaceBefore && !spaceBefore[2]) { start = max - spaceBefore[1].length; end = max; }
      if (spaceAfter && !spaceAfter[2]) { if (!start) start = max; end = max + spaceAfter[1].length; }
      if (start) return { start: start, end: end };
      if (spaceBefore && spaceBefore[2] && spaceBefore.index > min) {
        return { start: spaceBefore.index, end: spaceBefore.index + spaceBefore[2].length };
      }
      if (spaceAfter && spaceAfter[2]) {
        start = max + spaceAfter[2].length;
        return { start: start, end: start + spaceAfter[3].length };
      }
    }
  };

  // ---- commands ------------------------------------------------------------------

  proto.execCommand = function (name) {
    if (Object.prototype.hasOwnProperty.call(CodeMirror.commands, name) && CodeMirror.commands[name]) {
      CodeMirror.commands[name](this);
    } else if (name == "goLineLeft" || name == "goLineRight") {
      var forward = name == "goLineRight";
      var head = this.$primary().head;
      var target = this.$screenLineBoundary(head, forward);
      if (forward && target > head && target <= this.doc.getLength() && this.doc.slice(target - 1, target) !== "\n" &&
          target < this.doc.getLength() && this.doc.slice(target, target + 1) !== "\n") {
        target--; // wrapped line: stay on the last character of the visual line
      }
      this.$setSel([{ anchor: target, head: target }], 0);
      this.$afterDispatch();
    } else {
      console.log(name + " is not implemented");
    }
  };

  // ---- options -------------------------------------------------------------------

  proto.setOption = function (name, val) {
    switch (name) {
      case "keyMap": this.state.keyMap = val; break;
      case "textwidth": this.state.textwidth = val; break;
      default: this.options[name] = val;
    }
  };
  proto.getOption = function (name) {
    switch (name) {
      case "firstLineNumber": return 1;
      case "textwidth": return this.state.textwidth;
      case "keyMap": return this.state.keyMap || "vim";
      default: return this.options[name];
    }
  };
  proto.toggleOverwrite = function (on) { this.state.overwrite = on; };
  // "string", "comment" or "" for the token around `pos` (the host knows the syntax).
  proto.getTokenTypeAt = function (pos) {
    var type = this.host.tokenType ? this.$host().tokenType(this.indexFromPos(pos)) : "";
    return type || "";
  };
  proto.getMode = function () { return { name: this.getOption("mode") }; };
  // ---- folding -------------------------------------------------------------------
  //
  // A fold is a line range [header, last]. While closed, lines header+1..last
  // are hidden and the header line stands for the whole fold. Folds are kept
  // as two markers (end of the header line, end of the last line), so edits
  // around them move them; an edit that touches the hidden lines deletes the
  // fold. zc and zM find blocks by indentation (a block also takes a closing
  // bracket line at the header's indentation); zf{motion} folds any lines.
  // Closed folds are sent to the host as hidden ranges.

  proto.$foldLines = function (f) {
    return { header: this.posFromIndex(f.head.offset).line, last: this.posFromIndex(f.tail.offset).line };
  };
  proto.$foldChanged = function () {
    this.$foldCache = null;
    this.$layoutCache = null;
    this.$foldDirty = true;
  };
  proto.$addFold = function (header, last, closed) {
    if (last <= header) return null;
    for (var i = 0; i < this.$folds.length; i++) {
      var f = this.$folds[i], l = this.$foldLines(f);
      if (l.header == header && l.last == last) { f.closed = closed; this.$foldChanged(); return f; }
    }
    var fold = this.$newFold(header, last, closed);
    this.$foldChanged();
    return fold;
  };
  proto.$newFold = function (header, last, closed) {
    var fold = {
      head: new Marker(this, this.indexFromPos(new Pos(header, this.getLine(header).length)), 1),
      tail: new Marker(this, this.indexFromPos(new Pos(last, this.getLine(last).length)), -1),
      closed: closed
    };
    this.$folds.push(fold);
    return fold;
  };
  // $addFold for many blocks at once: existing folds are looked up in a map
  // instead of a scan of all folds per block (zM made thousands of folds
  // and scanned them all for each one).
  proto.$addFolds = function (blocks, closed) {
    if (!blocks.length) return;
    var existing = new Map();
    for (var i = 0; i < this.$folds.length; i++) {
      var l = this.$foldLines(this.$folds[i]);
      existing.set(l.header + ":" + l.last, this.$folds[i]);
    }
    for (var j = 0; j < blocks.length; j++) {
      var b = blocks[j], key = b.header + ":" + b.last, f = existing.get(key);
      if (f) f.closed = closed;
      else existing.set(key, this.$newFold(b.header, b.last, closed));
    }
    this.$foldChanged();
  };
  proto.$removeFold = function (f) {
    var i = this.$folds.indexOf(f);
    if (i < 0) return;
    this.$folds.splice(i, 1);
    f.head.clear();
    f.tail.clear();
    this.$foldChanged();
  };
  proto.$clearFolds = function () {
    if (!this.$folds.length) return;
    this.$folds = [];
    this.$foldChanged();
  };
  // Called before an edit of [from, to] is applied. Edits inside a fold
  // (`>>` on a closed fold, :s) keep it; an edit across its first or last
  // line end (`dd` on the header) deletes it.
  proto.$foldsBeforeChange = function (from, to) {
    for (var i = this.$folds.length - 1; i >= 0; i--) {
      var f = this.$folds[i], h = f.head.offset, t = f.tail.offset;
      if ((from < h && h < to) || (from < t && t < to) || (from <= h && t <= to && from < to)) this.$removeFold(f);
    }
    this.$foldChanged();
  };
  // $foldsBeforeChange for ascending, non-overlapping changes (old offsets).
  proto.$foldsBeforeChanges = function (froms, tos) {
    var n = froms.length;
    function lastFrom(p, strict) {
      var lo = 0, hi = n - 1, k = -1;
      while (lo <= hi) {
        var mid = (lo + hi) >> 1;
        if (strict ? froms[mid] < p : froms[mid] <= p) { k = mid; lo = mid + 1; } else hi = mid - 1;
      }
      return k;
    }
    for (var i = this.$folds.length - 1; i >= 0; i--) {
      var f = this.$folds[i], h = f.head.offset, t = f.tail.offset, a = lastFrom(h, true), b = lastFrom(t, true),
        c = lastFrom(h, false);
      if ((a >= 0 && h < tos[a]) || (b >= 0 && t < tos[b]) || (c >= 0 && t <= tos[c] && froms[c] < tos[c])) this.$removeFold(f);
    }
    this.$foldChanged();
  };
  // An operator in visual line mode gets [first line, start of the line
  // after the last]. When the last line is a closed fold's header, extend
  // the range over the fold (in place: vim.js passes the same objects on to
  // the operator).
  proto.$selectWholeFolds = function (ranges) {
    if (ranges.length != 1) return;
    var r = ranges[0], headLast = r.head.line > r.anchor.line || (r.head.line == r.anchor.line && r.head.ch >= r.anchor.ch);
    var end = headLast ? r.head : r.anchor;
    var start = end === r.head ? r.anchor : r.head;
    if (end.ch != 0 || end.line - 1 < start.line) return;
    var last = this.$foldEnd(end.line - 1);
    if (last > end.line - 1) end.line = last + 1;
  };
  // Last line of the closed fold whose header is `line`, or `line`.
  proto.$foldEnd = function (line) {
    if (!this.$folds.length) return line;
    var spans = this.$hiddenLines();
    for (var i = 0; i < spans.length; i++) {
      if (spans[i][0] == line + 1) return spans[i][1];
      if (spans[i][0] > line + 1) break;
    }
    return line;
  };
  // Closed folds as merged, sorted [firstHiddenLine, lastHiddenLine] pairs.
  proto.$hiddenLines = function () {
    if (this.$foldCache) return this.$foldCache;
    var spans = [];
    for (var i = 0; i < this.$folds.length; i++) {
      if (!this.$folds[i].closed) continue;
      var l = this.$foldLines(this.$folds[i]);
      if (l.last > l.header) spans.push([l.header + 1, l.last]);
    }
    spans.sort(function (a, b) { return a[0] - b[0] || b[1] - a[1]; });
    var merged = [];
    spans.forEach(function (s) {
      var top = merged[merged.length - 1];
      if (top && s[0] <= top[1]) top[1] = Math.max(top[1], s[1]);
      else merged.push([s[0], s[1]]);
    });
    return (this.$foldCache = merged);
  };
  proto.$isHidden = function (line) {
    var spans = this.$hiddenLines(), lo = 0, hi = spans.length - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (line < spans[mid][0]) hi = mid - 1;
      else if (line > spans[mid][1]) lo = mid + 1;
      else return true;
    }
    return false;
  };
  // Folds containing `line` (header..last), innermost first.
  proto.$foldsAt = function (line) {
    var cm = this, out = [];
    this.$folds.forEach(function (f) {
      var l = cm.$foldLines(f);
      if (l.header <= line && line <= l.last) out.push({ fold: f, header: l.header, last: l.last });
    });
    out.sort(function (a, b) { return (a.last - a.header) - (b.last - b.header); });
    return out;
  };

  proto.$indentOf = function (line) {
    var text = this.getLine(line);
    if (!/\S/.test(text)) return null;
    return countColumn(text.match(/^\s*/)[0], this.options.tabSize);
  };
  function isClosingLine(text) { return /^\s*([\]\)\}]|end\b)/.test(text); }
  // The block whose header is `header`, or null.
  proto.$blockFrom = function (header) {
    var indent = this.$indentOf(header), lastLine = this.lastLine();
    if (indent == null) return null;
    var last = header, i = header + 1;
    for (; i <= lastLine; i++) {
      var d = this.$indentOf(i);
      if (d == null) continue;
      if (d <= indent) break;
      last = i;
    }
    if (i <= lastLine && this.$indentOf(i) == indent && isClosingLine(this.getLine(i))) last = i;
    return last > header ? { header: header, last: last } : null;
  };
  // Every block $blockFrom would find, for all lines, in one pass: a stack of
  // headers still open. A non-blank line closes every header indented at
  // least as deep; their blocks end at the previous non-blank line, or on
  // this line when it is a closing bracket at the header's indentation.
  // The host may compute them natively (VimRuntime.foldKernel): it gets the
  // text and returns an Int32Array of [header, last, ...], or null.
  proto.$allBlocks = function () {
    var flat = this.$nativeBlocks();
    if (!flat) return this.$allBlocksJS();
    var blocks = new Array(flat.length >> 1);
    for (var i = 0; i < blocks.length; i++) blocks[i] = { header: flat[2 * i], last: flat[2 * i + 1] };
    return blocks;
  };
  proto.$nativeBlocks = function () {
    return this.host.foldBlocks ? this.host.foldBlocks(this.doc.toString(), this.options.tabSize) : null;
  };
  // For VimEngine.foldBlocks(): the blocks as an Int32Array of [header, last, ...].
  proto.$foldBlocksFlat = function () {
    var flat = this.$nativeBlocks();
    if (flat) return flat;
    var blocks = this.$allBlocksJS(), out = new Int32Array(blocks.length * 2);
    for (var i = 0; i < blocks.length; i++) { out[2 * i] = blocks[i].header; out[2 * i + 1] = blocks[i].last; }
    return out;
  };
  proto.$allBlocksJS = function () {
    var blocks = [], stack = [], prev = -1, lastLine = this.lastLine();
    for (var i = 0; i <= lastLine; i++) {
      var d = this.$indentOf(i);
      if (d == null) continue;
      var closing = null;
      while (stack.length && stack[stack.length - 1].indent >= d) {
        var h = stack.pop(), last = prev;
        if (h.indent == d) {
          if (closing == null) closing = isClosingLine(this.getLine(i));
          if (closing) last = i;
        }
        if (last > h.line) blocks.push({ header: h.line, last: last });
      }
      stack.push({ line: i, indent: d });
      prev = i;
    }
    while (stack.length) {
      var open = stack.pop();
      if (prev > open.line) blocks.push({ header: open.line, last: prev });
    }
    return blocks.sort(function (a, b) { return a.header - b.header; });
  };
  // The innermost block that contains `line` without starting on it.
  proto.$blockAround = function (line) {
    var indent = this.$indentOf(line), lastLine = this.lastLine();
    for (var n = line + 1; indent == null && n <= lastLine; n++) indent = this.$indentOf(n);
    if (indent == null) return null;
    var closing = isClosingLine(this.getLine(line));
    for (var h = line - 1; h >= 0; h--) {
      var d = this.$indentOf(h);
      if (d == null || d > indent || (d == indent && !closing)) continue;
      var block = this.$blockFrom(h);
      if (block && block.last >= line) return block;
      if (d < indent) indent = d;
    }
    return null;
  };
  proto.$blockAt = function (line) {
    return this.$blockFrom(line) || this.$blockAround(line);
  };

  // zo zO zc za zR zM zE zd zD
  proto.$foldCommand = function (op) {
    var cur = this.getCursor(), line = cur.line, cm = this;
    var around = this.$foldsAt(line);
    var closedHere = around.filter(function (a) { return a.fold.closed && a.header == line; });
    var outerClosed = closedHere[closedHere.length - 1];
    if (op == "toggle") op = outerClosed ? "open" : "close";
    switch (op) {
      case "open":
        if (outerClosed) outerClosed.fold.closed = false;
        break;
      case "openAll":
        around.forEach(function (a) { a.fold.closed = false; });
        break;
      case "close":
        // The innermost of: open folds around the cursor, the block around it.
        var open = around.filter(function (a) { return !a.fold.closed; })[0];
        var block = outerClosed ? this.$blockAround(line) : this.$blockAt(line);
        if (block && (!open || block.last - block.header < open.last - open.header)) {
          // A fold for this block may exist already (opened earlier).
          open = { fold: this.$addFold(block.header, block.last, true), header: block.header };
        }
        if (!open) return;
        open.fold.closed = true;
        if (open.header != line) this.setCursor(new Pos(open.header, Math.min(cur.ch, this.getLine(open.header).length)));
        break;
      case "openEverything":
        this.$folds.forEach(function (f) { f.closed = false; });
        break;
      case "closeEverything":
        this.$folds.forEach(function (f) { f.closed = true; });
        this.$addFolds(this.$allBlocks(), true);
        var top = this.$hiddenLines().filter(function (s) { return s[0] <= line && line <= s[1]; })[0];
        if (top) this.setCursor(new Pos(top[0] - 1, 0));
        break;
      case "delete":
        var target = outerClosed || around[0];
        if (target) this.$removeFold(target.fold);
        break;
      case "deleteAll":
        around.forEach(function (a) { cm.$removeFold(a.fold); });
        break;
      case "eliminate":
        this.$clearFolds();
        break;
    }
    this.$foldChanged();
  };
  // CodeMirror API (used by the upstream tests): toggles the fold starting on pos.line.
  proto.foldCode = function (pos, options, force) {
    var line = typeof pos == "number" ? pos : pos.line, cm = this;
    var existing = this.$folds.filter(function (f) { return cm.$foldLines(f).header == line; })[0];
    if (existing) {
      existing.closed = force == "fold" ? true : force == "unfold" ? false : !existing.closed;
      this.$foldChanged();
    } else if (force != "unfold") {
      var block = this.$blockFrom(line);
      if (block) this.$addFold(block.header, block.last, true);
    }
    if (!this.curOp) this.$flush();
  };
  proto.isFolded = function (pos) {
    var line = pos.line, cm = this;
    return this.$folds.some(function (f) { return f.closed && cm.$foldLines(f).header == line; });
  };
  // A cursor that ends up in hidden lines (search, G, marks...) opens the folds around it.
  // Jumps that leave folds closed (Vim's 'foldopen' default leaves out
  // "jump" and vertical moves); the cursor goes to the fold's first line.
  var KEEPS_FOLDS_CLOSED = {
    moveToLineOrEdgeOfDocument: 1, moveByScroll: 1, moveByPage: 1, moveByLines: 1, moveByDisplayLines: 1,
    moveToTopLine: 1, moveToMiddleLine: 1, moveToBottomLine: 1
  };
  // A cursor that ends up in hidden lines (search, marks, %, undo...) opens
  // the folds around it; after a jump (G, <C-d>, H...) it moves onto the fold.
  proto.$revealCursor = function () {
    var undoing = this.$undoing;
    this.$undoing = false;
    var pos = this.posFromIndex(this.$primary().head), line = pos.line;
    if (!this.$isHidden(line)) return;
    var vim = this.state.vim, motion = vim && vim.lastMotion;
    if (!undoing && vim && !vim.visualMode && !vim.insertMode && this.sel.ranges.length == 1 &&
        motion && KEEPS_FOLDS_CLOSED[motion.name]) {
      var span = this.$hiddenLines().filter(function (s) { return s[0] <= line && line <= s[1]; })[0];
      var header = span[0] - 1, text = this.getLine(header);
      var ch = Math.min(pos.ch, Math.max(0, text.length - 1));
      if (motion.name == "moveToLineOrEdgeOfDocument") ch = text.search(/\S|$/);
      var offset = this.indexFromPos(new Pos(header, ch));
      this.$setSel([{ anchor: offset, head: offset }], 0);
      return;
    }
    this.$foldsAt(line).forEach(function (a) { if (a.header < line) a.fold.closed = false; });
    this.$foldChanged();
  };
  // Sends closed folds as [hiddenStart, hiddenEnd, lineCount, ...]: the hidden
  // lines (from the start of the first to the start of the line after the last).
  proto.$sendFolds = function () {
    if (!this.$foldDirty) return;
    this.$foldDirty = false;
    var flat = [], doc = this.doc, len = doc.getLength(), lastLine = this.lastLine();
    this.$hiddenLines().forEach(function (s) {
      var start = doc.lineStart(s[0]);
      var end = s[1] >= lastLine ? len : doc.lineStart(s[1] + 1);
      flat.push(start, end, s[1] - s[0] + 1);
    });
    var key = flat.join(",");
    if (key === this.$sentFolds) return;
    this.$sentFolds = key;
    if (this.host.folds) this.host.folds(flat);
  };

  // ---- view geometry ----------------------------------------------------------------
  //
  // Delegated to the host. Without one, a virtual monospace layout is used:
  // HEADLESS_CHAR_WIDTH × HEADLESS_LINE_HEIGHT cells, a viewport set by
  // setSize(), and character wrapping when the lineWrapping option is on.

  proto.$cols = function () {
    if (!this.options.lineWrapping) return Infinity;
    return Math.max(1, Math.floor(this.options.viewportWidth / HEADLESS_CHAR_WIDTH));
  };
  proto.$layout = function () {
    var cols = this.$cols();
    if (this.$layoutCache && this.$layoutCache.cols === cols) return this.$layoutCache;
    var lines = this.doc.lines, prefix = new Array(lines.length), total = 0;
    var hidden = this.$folds.length ? this.$hiddenLines() : [], span = 0;
    for (var i = 0; i < lines.length; i++) {
      prefix[i] = total;
      while (span < hidden.length && hidden[span][1] < i) span++;
      if (span < hidden.length && hidden[span][0] <= i) continue; // folded away
      total += cols === Infinity ? 1 : Math.max(1, Math.ceil(lines[i].length / cols));
    }
    return (this.$layoutCache = { cols: cols, prefix: prefix, total: total });
  };
  proto.$rowsOf = function (line, layout) {
    return (line + 1 < layout.prefix.length ? layout.prefix[line + 1] : layout.total) - layout.prefix[line];
  };
  // Screen row (global) and column of an offset.
  proto.$visual = function (offset) {
    var layout = this.$layout(), pos = this.posFromIndex(offset);
    var r = layout.cols === Infinity ? 0 : Math.max(0, Math.min(Math.floor(pos.ch / layout.cols), this.$rowsOf(pos.line, layout) - 1));
    return { row: layout.prefix[pos.line] + r, col: pos.ch - (layout.cols === Infinity ? 0 : r * layout.cols), line: pos.line, r: r };
  };
  proto.$offsetAtVisual = function (row, col) {
    var layout = this.$layout(), prefix = layout.prefix;
    row = clamp(row, 0, layout.total - 1);
    var lo = 0, hi = prefix.length - 1;
    while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (prefix[mid] <= row) lo = mid; else hi = mid - 1; }
    var line = lo, r = row - prefix[line], len = this.doc.lines[line].length;
    var rows = this.$rowsOf(line, layout), cols = layout.cols;
    var start = cols === Infinity ? 0 : r * cols;
    var end = cols === Infinity || r == rows - 1 ? len : (r + 1) * cols;
    return this.indexFromPos(new Pos(line, clamp(start + Math.max(0, col), start, end)));
  };

  proto.defaultTextHeight = function () {
    var h = this.host.lineHeight();
    return h > 0 ? h : HEADLESS_LINE_HEIGHT;
  };
  proto.charCoords = function (pos) {
    var r = this.$host().coords(this.indexFromPos(pos));
    if (r && r.length >= 3) return { left: r[0], top: r[1], bottom: r[2] };
    var v = this.$visual(this.indexFromPos(pos));
    return { left: v.col * HEADLESS_CHAR_WIDTH, top: v.row * HEADLESS_LINE_HEIGHT, bottom: (v.row + 1) * HEADLESS_LINE_HEIGHT };
  };
  proto.coordsChar = function (coords) {
    var offset = this.$host().offsetAt(coords.left, coords.top);
    if (offset == null || offset < 0) {
      offset = this.$offsetAtVisual(Math.floor(coords.top / HEADLESS_LINE_HEIGHT), Math.round(coords.left / HEADLESS_CHAR_WIDTH));
    }
    return this.posFromIndex(offset);
  };
  proto.getScrollInfo = function () {
    var r = this.$host().scrollInfo();
    if (r && r.length >= 6) {
      return { left: r[0], top: r[1], width: r[2], height: r[3], clientWidth: r[4], clientHeight: r[5] };
    }
    var o = this.options;
    return {
      left: this.headlessScroll.left, top: this.headlessScroll.top,
      width: o.viewportWidth, height: Math.max(this.$layout().total * HEADLESS_LINE_HEIGHT, o.viewportHeight),
      clientWidth: o.viewportWidth, clientHeight: o.viewportHeight
    };
  };
  proto.$clampScroll = function (top) {
    var max = Math.max(0, this.$layout().total * HEADLESS_LINE_HEIGHT - this.options.viewportHeight);
    return clamp(top, 0, max);
  };
  proto.scrollTo = function (x, y) {
    if (x != null) this.headlessScroll.left = x;
    if (y != null) this.headlessScroll.top = this.$clampScroll(y);
    this.$host().scrollTo(x == null ? NaN : x, y == null ? NaN : y);
  };
  // Inside an operation the scroll happens when it ends (like CodeMirror),
  // so a command that edits many places scrolls once.
  proto.scrollIntoView = function (pos, margin) {
    var offset = pos ? this.indexFromPos(pos) : this.$primary().head;
    if (this.curOp) { this.curOp.$scroll = { offset: offset, margin: margin || 0 }; return; }
    this.$scrollNow(offset, margin);
  };
  proto.$scrollNow = function (offset, margin) {
    margin = margin || 0;
    var info = this.$host().scrollInfo();
    if (info && info.length >= 6) { this.host.scrollIntoView(offset, margin); return; }
    var row = this.$visual(offset).row, h = HEADLESS_LINE_HEIGHT, top = this.headlessScroll.top;
    var height = this.options.viewportHeight;
    if (row * h - margin < top) top = row * h - margin;
    else if ((row + 1) * h + margin > top + height) top = (row + 1) * h + margin - height;
    this.headlessScroll.top = this.$clampScroll(top);
    this.$host().scrollIntoView(offset, margin);
  };
  proto.findPosV = function (start, amount, unit, goalColumn) {
    var count = Math.round(Math.abs(amount)), forward = amount > 0;
    var offset = this.indexFromPos(start), viaHost = true;
    var goal = goalColumn == null ? -1 : goalColumn;
    for (var i = 0; i < count; i++) {
      var next = this.$host().moveVertically(offset, forward, unit == "page", goal);
      if (next == null || next < 0) { viaHost = false; break; }
      offset = next;
    }
    if (!viaHost) {
      var v = this.$visual(this.indexFromPos(start)), total = this.$layout().total;
      var step = unit == "page" ? Math.max(1, Math.floor(this.options.viewportHeight / HEADLESS_LINE_HEIGHT)) : 1;
      var row = v.row + (forward ? 1 : -1) * step * count;
      var col = goalColumn == null ? v.col : Math.round(goalColumn / HEADLESS_CHAR_WIDTH);
      offset = row < 0 ? 0 : row >= total ? this.doc.getLength() : this.$offsetAtVisual(row, col);
    }
    var pos = this.posFromIndex(offset);
    if ((amount < 0 && offset == 0 && goalColumn != 0 && start.line == 0 && start.ch != 0) ||
        (amount > 0 && offset == this.doc.getLength() && pos.ch != goalColumn && start.line == pos.line)) {
      pos.hitSide = true;
    }
    return pos;
  };
  // Start or end of the screen line containing `offset`.
  proto.$screenLineBoundary = function (offset, forward) {
    var target = this.$host().lineBoundary(offset, forward);
    if (target != null && target >= 0) return target;
    var v = this.$visual(offset);
    return this.$offsetAtVisual(v.row, forward ? Infinity : 0);
  };

  // ---- focus & DOM stand-ins ---------------------------------------------------------

  proto.focus = function () { this.$host().event("focus", ""); };
  proto.blur = function () {};
  proto.getInputField = function () { return this.inputField; };
  proto.getWrapperElement = function () { return this.wrapper; };
  proto.setSize = function (width, height) {
    if (width != null) this.options.viewportWidth = parseFloat(width) || this.options.viewportWidth;
    if (height != null) this.options.viewportHeight = parseFloat(height) || this.options.viewportHeight;
    this.$layoutCache = null;
    this.scrollTo(null, this.headlessScroll.top);
  };
  proto.refresh = function () {};
  proto.save = function () { this.$host().event("save", ""); };

  // ---- multiple selections -------------------------------------------------------------

  proto.isInMultiSelectMode = function () { return this.sel.ranges.length > 1; };
  proto.virtualSelectionMode = function () { return !!this.virtualSelection; };
  proto.forEachSelection = function (command) {
    this.virtualSelection = {
      ranges: this.sel.ranges.map(function (r) { return { anchor: r.anchor, head: r.head }; }),
      primary: this.sel.primary
    };
    for (var i = 0; i < this.virtualSelection.ranges.length; i++) {
      var range = this.virtualSelection.ranges[i];
      if (!range) continue;
      this.$setSel([range], 0);
      command();
      var now = this.sel.ranges[0];
      this.virtualSelection.ranges[i] = { anchor: now.anchor, head: now.head };
    }
    var vs = this.virtualSelection;
    this.virtualSelection = null;
    this.$setSel(vs.ranges, vs.primary);
  };

  // ---- dialogs: the `:` / `/` command line and messages ----------------------------------

  function findInput(node) { return node && node.getElementsByTagName ? node.getElementsByTagName("input")[0] : null; }
  function splitAround(node, input) {
    var before = "", after = "", seen = false;
    (function walk(n) {
      if (n === input) { seen = true; return; }
      if (n.nodeType === 3) { if (seen) after += n.nodeValue; else before += n.nodeValue; return; }
      for (var i = 0; i < n.childNodes.length; i++) walk(n.childNodes[i]);
    })(node);
    return { before: before, after: after };
  }
  // vim.js shows every message in red; these ones are not errors.
  var infoMessage = /^(\d+ lines yanked|Found \d+ matches|No matches found for pattern|Codemirror-vim version|\s)/;
  function isErrorTemplate(node) {
    for (var n = node; n && n.nodeType === 1; n = n.childNodes[0]) if (n.style && n.style.color === "red") return true;
    return false;
  }

  proto.openDialog = function (template, callback, options) {
    options = options || {};
    var cm = this, closed = false;
    var input = findInput(template);
    var dialog = { template: template, callback: callback, options: options, input: input, close: close,
                   prefix: (template.textContent || "").charAt(0) };
    if (input) {
      this.$closeNotification();
      input.value = options.value || "";
      input.selectionStart = input.selectionEnd = input.value.length;
      this.dialog = dialog;
    } else {
      this.banner = dialog; // e.g. "recording @q": shown, but keys keep going to vim
    }
    this.wrapper.appendChild(template);
    function close(newVal) {
      if (typeof newVal == "string") {
        if (input) { input.value = newVal; input.selectionStart = input.selectionEnd = newVal.length; }
        cm.$emitState();
        return;
      }
      if (closed) return;
      closed = true;
      if (cm.dialog === dialog) cm.dialog = null;
      template.remove();
      if (cm.banner === dialog) cm.banner = null;
      if (options.onClose) options.onClose(template);
      signal(cm, "dialog");
      cm.$emitState();
    }
    signal(this, "dialog");
    this.$emitState();
    return close;
  };
  proto.$closeNotification = function (replacement) {
    if (this.state.currentNotificationClose) this.state.currentNotificationClose();
    this.state.currentNotificationClose = replacement;
  };
  proto.openNotification = function (template, options) {
    var cm = this, closed = false, timer = 0;
    // A VimKit error stays over later messages of the same key ("%yy shows
    // E354, not "1 line yanked").
    if (this.$keyDepth && this.$keyError) return function () {};
    function close() {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      if (cm.notification === note) cm.notification = null;
      template.remove();
      cm.$emitState();
    }
    var text = template.textContent;
    // Vim reports yanks only above 'report' (2) lines.
    var yanked = /^(\d+) lines yanked/.exec(text);
    if (yanked && +yanked[1] <= 2) return function () {};
    this.$closeNotification(close);
    var note = { text: text, isError: isErrorTemplate(template) && !infoMessage.test(text) };
    this.notification = note;
    this.wrapper.appendChild(template);
    var duration = options && typeof options.duration !== "undefined" ? options.duration : 5000;
    if (duration) timer = setTimeout(close, duration);
    this.$emitState();
    return close;
  };

  function keyCodeFor(key) {
    return key == "Enter" ? 13 : key == "Escape" ? 27 : key == "Backspace" ? 8 : key == "Tab" ? 9 : 0;
  }
  function makeEvent(e, target) {
    return {
      key: e.key, code: e.code || "", ctrlKey: !!e.ctrlKey, altKey: !!e.altKey,
      metaKey: !!e.metaKey, shiftKey: !!e.shiftKey, keyCode: keyCodeFor(e.key), target: target,
      defaultPrevented: false,
      preventDefault: function () { this.defaultPrevented = true; },
      stopPropagation: function () {}
    };
  }
  function wordStartBefore(text, pos) {
    var i = pos;
    while (i > 0 && /\s/.test(text.charAt(i - 1))) i--;
    if (i > 0 && wordChar.test(text.charAt(i - 1))) while (i > 0 && wordChar.test(text.charAt(i - 1))) i--;
    else if (i > 0) i--;
    return i;
  }

  proto.$dialogKey = function (e) {
    var d = this.dialog, input = d.input, options = d.options;
    var ev = makeEvent(e, input);
    if (options.onKeyDown && options.onKeyDown(ev, input.value, d.close)) return;
    if (this.dialog !== d) return;
    if (ev.key == "Enter") {
      var value = input.value;
      if (d.prefix == "/" || d.prefix == "?") value = takeSearchOffset(value, d.prefix);
      if (d.callback) d.callback(value);
      if (options.closeOnEnter !== false) d.close();
      return;
    }
    if (ev.key == "Escape") { d.close(); return; }
    if (!ev.defaultPrevented) {
      var v = input.value, at = clamp(input.selectionEnd, 0, v.length), changed = false;
      if (ev.ctrlKey && ev.key == "w") {
        var s = wordStartBefore(v, at);
        input.value = v.slice(0, s) + v.slice(at); at = s; changed = true;
      } else if (ev.ctrlKey || ev.metaKey) {
        // other control keys are not text
      } else if (ev.key == "Backspace") {
        if (at > 0) { input.value = v.slice(0, at - 1) + v.slice(at); at--; changed = true; }
      } else if (ev.key == "Delete") {
        if (at < v.length) { input.value = v.slice(0, at) + v.slice(at + 1); changed = true; }
      } else if (ev.key == "ArrowLeft") { at = Math.max(0, at - 1);
      } else if (ev.key == "ArrowRight") { at = Math.min(v.length, at + 1);
      } else if (ev.key == "Home") { at = 0;
      } else if (ev.key == "End") { at = v.length;
      } else if (ev.key.length == 1 || ev.key == "Tab") {
        var ch = ev.key == "Tab" ? "\t" : ev.key;
        input.value = v.slice(0, at) + ch + v.slice(at); at++; changed = true;
      }
      input.selectionStart = input.selectionEnd = at;
      if (changed && options.onInput) options.onInput(ev, input.value, d.close);
    }
    if (this.dialog === d && options.onKeyUp) options.onKeyUp(ev, input.value, d.close);
  };

  // ---- state reporting ---------------------------------------------------------------------

  proto.$emitState = function () {
    // Mode changes inside one key (:normal toggles insert mode on every line)
    // are reported once, by the $flush that ends the key.
    if (this.$keyDepth) return;
    var vim = this.state.vim, d = this.dialog, cursor = this.$primary().head;
    if (vim && vim.visualMode && vim.sel && vim.sel.head) cursor = this.indexFromPos(vim.sel.head);
    var state = {
      mode: this.$mode,
      subMode: this.$subMode,
      pending: (vim && !vim.insertMode && vim.status) || "",
      insertModeReturn: !!(vim && vim.insertModeReturn),
      cursor: cursor,
      commandLine: null,
      banner: this.banner ? this.banner.template.textContent : null,
      message: this.notification ? this.notification.text : null,
      messageIsError: !!(this.notification && this.notification.isError)
    };
    if (d && d.input) {
      var parts = splitAround(d.template, d.input);
      state.commandLine = { prefix: parts.before, text: d.input.value, cursor: d.input.selectionEnd, description: parts.after };
    }
    var json = JSON.stringify(state);
    if (json === this.$lastState) return;
    this.$lastState = json;
    this.host.state(json);
  };

  // ---- key input ---------------------------------------------------------------------------

  // e: { key, code, ctrlKey, altKey, metaKey, shiftKey } in DOM KeyboardEvent terms.
  // Returns true when vim consumed the key; false means the native view should
  // handle it (in insert mode that inserts text).
  proto.handleKeyEvent = function (e) {
    this.$keyDepth = (this.$keyDepth || 0) + 1;
    try {
      return this.$handleKeyEvent(e);
    } finally {
      if (--this.$keyDepth === 0) {
        this.$keyError = false;
        var scroll = this.$keyScroll;
        this.$keyScroll = null;
        this.$flush();
        if (scroll && scroll.pending) this.$scrollNow(scroll.pending.offset, scroll.pending.margin);
        if (scroll && scroll.cursor) this.scrollIntoView();
      }
    }
  };
  proto.$handleKeyEvent = function (e) {
    activeCm = this;
    currentEvent = e;
    ensureRegisters();
    this.$resolveInsertStart();
    if (this.dialog && this.dialog.input) {
      recordPromptKey(e);
      if (!this.$promptRegisterKey(e)) this.$dialogKey(e);
      this.$clipNormalCursor();
      this.$emitState();
      return true;
    }
    var vim = this.state.vim;
    if (!vim) return false;
    if (e.key == "." && !e.ctrlKey && !e.metaKey && !e.altKey && !vim.insertMode && !vim.visualMode
        && !vim.inputState.operator && !vim.inputState.keyBuffer.length) {
      bumpNumberedPaste(vim);
    }
    // vim.js listens to keydown on the input field to record insert-mode
    // deletions for `.` repeat.
    var listeners = this.inputField._listeners.keydown;
    if (listeners) listeners.slice().forEach(function (fn) { fn(e); });
    // Macro keys were recorded after 'langmap'; they replay as they are.
    var key = Vim.vimKeyFromEvent(e, this.$macroKeys ? null : vim);
    if (!key) return false;
    this.$recentKeys = ((this.$recentKeys || "") + key).slice(-16);
    if (key == "<Esc>" && !vim.insertMode && !vim.visualMode && this.searchQuery) {
      var searchState = vim.searchState_;
      if (searchState) {
        this.removeOverlay(searchState.getOverlay());
        searchState.setOverlay(null);
      }
    }
    vim.status = (vim.status || "") + key;
    // A cursor key in insert mode starts a new undo step, and the insert
    // starts again where the cursor lands (for <C-w> and <C-u>).
    if (vim.insertMode && /^<([SCM]-)*(Left|Right|Up|Down|Home|End|PageUp|PageDown)>$/.test(key)) {
      this.history.close();
      this.$insertStartPending = true;
    }
    // <CR> in insert mode breaks the line with 'autoindent' rules (the view
    // would insert a bare line break).
    if (key == "<CR>" && vim.insertMode && !vim.inputState.keyBuffer.length && !vim.expectLiteralNext) {
      CodeMirror.commands.newlineAndIndent(this);
      this.$flush();
      return true;
    }
    var result = Vim.multiSelectHandleKey(this, key, "user");
    vim = Vim.maybeInitVimState_(this);
    if (!result && vim.insertMode && this.state.overwrite) {
      if (e.key && e.key.length == 1 && !e.ctrlKey && !e.metaKey) {
        result = true;
        this.overWriteSelection(e.key);
      } else if (e.key == "Backspace") {
        result = true;
        this.$replaceBackspace();
      }
    }
    if (!result && vim.insertMode) vim.status = "";
    if (result) this.$clipNormalCursor();
    if (!vim.insertMode) this.history.close();
    if (result) signal(this, "vim-keypress", key);
    this.$flush();
    // Outside insert mode nothing may fall through to the text view, except
    // Command shortcuts (copy, menu items, ...).
    return !!result || (!vim.insertMode && !e.metaKey);
  };

  // Types text the way the native view would when vim does not consume a key.
  proto.$defaultInput = function (e) {
    var vim = this.state.vim;
    if (!vim || !vim.insertMode || e.ctrlKey || e.metaKey) return;
    var text = e.key == "Enter" ? "\n" : e.key == "Tab" ? "\t" : e.key.length == 1 ? e.key : null;
    if (e.key == "Backspace") { this.$deleteChar(-1); return; }
    // Cursor keys (in a window the text view moves the cursor itself).
    var cur = this.getCursor(), len = this.getLine(cur.line).length;
    switch (e.key) {
      case "ArrowLeft": if (cur.ch > 0) this.setCursor(cur.line, cur.ch - 1); return;
      case "ArrowRight": if (cur.ch < len) this.setCursor(cur.line, cur.ch + 1); return;
      case "ArrowUp": if (cur.line > 0) this.setCursor(cur.line - 1, Math.min(cur.ch, this.getLine(cur.line - 1).length)); return;
      case "ArrowDown": if (cur.line < this.lastLine()) this.setCursor(cur.line + 1, Math.min(cur.ch, this.getLine(cur.line + 1).length)); return;
      case "Home": this.setCursor(cur.line, 0); return;
      case "End": this.setCursor(cur.line, len); return;
    }
    if (e.key == "Delete") { this.$deleteChar(1); return; }
    if (text != null) this.$replaceRanges(function () { return text; }, "end", "+input");
  };

  var notationKeys = {
    cr: "Enter", enter: "Enter", return: "Enter", esc: "Escape", bs: "Backspace", del: "Delete",
    tab: "Tab", space: " ", up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight",
    home: "Home", end: "End", pageup: "PageUp", pagedown: "PageDown", lt: "<", bslash: "\\",
    bar: "|", ins: "Insert", insert: "Insert", nl: "Enter"
  };
  function eventFromNotation(token) {
    var e = { key: token, code: "", ctrlKey: false, altKey: false, metaKey: false, shiftKey: false };
    if (token == "\n" || token == "\r") { e.key = "Enter"; return e; }
    if (token == "\t") { e.key = "Tab"; return e; }
    if (token.length < 3 || token.charAt(0) != "<") return e;
    var m = /^<((?:[CSAMDcsamd]-)*)(.+)>$/.exec(token);
    if (!m) return null;
    var name = m[2];
    // As in Vim, <x> without a modifier is not a key: "<&>" is three characters.
    if (name.length == 1 && !m[1]) return null;
    if (name.length > 1) {
      var special = notationKeys[name.toLowerCase()];
      if (special) name = special;
      else if (!/^F\d{1,2}$/i.test(name)) return null;
    }
    e.key = name;
    var mods = m[1].toUpperCase();
    e.ctrlKey = mods.indexOf("C-") >= 0;
    e.shiftKey = mods.indexOf("S-") >= 0;
    e.altKey = mods.indexOf("A-") >= 0 || mods.indexOf("M-") >= 0;
    e.metaKey = mods.indexOf("D-") >= 0;
    return e;
  }
  function tokenizeKeys(keys) {
    var out = [], i = 0;
    while (i < keys.length) {
      if (keys.charAt(i) == "<") {
        var close = keys.indexOf(">", i + 2);
        if (close > 0 && close - i <= 16) {
          var token = keys.slice(i, close + 1);
          if (eventFromNotation(token)) { out.push(token); i = close + 1; continue; }
        }
      }
      var code = keys.charCodeAt(i);
      var len = code >= 0xd800 && code <= 0xdbff ? 2 : 1;
      out.push(keys.substr(i, len));
      i += len;
    }
    return out;
  }

  // Feeds keys in Vim notation ("ciwfoo<Esc>", ":s/a/b/g<CR>"), typing text
  // for keys vim does not consume, like a user would.
  proto.feedKeys = function (keys) {
    var tokens = tokenizeKeys(String(keys));
    for (var i = 0; i < tokens.length; i++) {
      var e = eventFromNotation(tokens[i]);
      if (!this.handleKeyEvent(e)) this.$defaultInput(e);
    }
  };

  // ---- native view → model ----------------------------------------------------------------

  // The native view changed text on its own (typing in insert mode, paste,
  // dictation, autocorrect).
  proto.hostReplace = function (from, to, text) {
    this.$flushEdits();
    this.$resolveInsertStart();
    var vim = this.state.vim;
    var grouped = vim && vim.insertMode;
    if (!grouped) this.history.close();
    this.$applyChange(from, to, text, true, "+input");
    if (!grouped) this.history.close();
    this.$afterDispatch();
  };
  proto.hostSelect = function (flat, primary) {
    this.$flushEdits();
    var ranges = [];
    for (var i = 0; i + 1 < flat.length; i += 2) ranges.push({ anchor: flat[i], head: flat[i + 1] });
    if (!ranges.length) return;
    var same = ranges.length === this.sel.ranges.length && ranges.every(function (r, k) {
      var c = this.sel.ranges[k];
      return c.anchor === r.anchor && c.head === r.head;
    }, this);
    if (same) return;
    this.$setSel(ranges, primary, true);
    this.$resolveInsertStart();
    this.$afterDispatch();
  };
  proto.hostSetValue = function (text) {
    this.$edits = null; // the host's text replaces anything not yet sent
    var head = this.$primary().head;
    this.$layoutCache = null;
    this.doc.setText(text);
    this.history.clear();
    this.$clearFolds();
    this.marks = Object.create(null);
    var o = Math.min(head, this.doc.getLength());
    this.$setSel([{ anchor: o, head: o }], 0, true);
    this.curOp = null;
    this.$sendFolds();
    this.$emitState();
  };
  proto.cursorOffset = function () { return this.$primary().head; };
  proto.selectionOffsets = function () {
    var flat = [];
    this.sel.ranges.forEach(function (r) { flat.push(r.anchor, r.head); });
    return flat;
  };
  proto.exec = function (command) {
    activeCm = this;
    ensureRegisters();
    Vim.handleEx(this, command);
    this.history.close();
    this.$flush();
  };
  proto.destroy = function () {
    Vim.leaveVimMode(this);
    this.$closeNotification();
  };

  // ---------------------------------------------------------------------------
  // Boot the engine
  // ---------------------------------------------------------------------------

  var Vim = global.initVim(CodeMirror);
  CodeMirror.Vim = Vim;

  // Folding keys (codemirror-vim leaves them to the editor).
  Vim.defineAction("vimkitFold", function (cm, args) { cm.$foldCommand(args.op); });
  [["zo", "open"], ["zO", "openAll"], ["zc", "close"], ["zC", "close"], ["za", "toggle"], ["zA", "toggle"],
   ["zR", "openEverything"], ["zM", "closeEverything"], ["zd", "delete"], ["zD", "deleteAll"], ["zE", "eliminate"]
  ].forEach(function (k) {
    Vim.mapCommand(k[0], "action", "vimkitFold", { op: k[1] }, { context: "normal" });
  });
  Vim.defineOperator("vimkitFoldCreate", function (cm, args, ranges) {
    var a = ranges[0].anchor, h = ranges[0].head;
    var start = a.line < h.line || (a.line == h.line && a.ch <= h.ch) ? a : h, end = start === a ? h : a;
    var last = end.ch == 0 && end.line > start.line ? end.line - 1 : end.line;
    cm.$addFold(start.line, last, true);
    return new Pos(start.line, start.ch);
  });
  Vim.mapCommand("zf", "operator", "vimkitFoldCreate", {}, {});
  // Linewise operators (dd, yy, >>, cc...) take a closed fold as one line, as in Vim.
  Vim.defineMotion("expandToLine", function (cm, head, motionArgs) {
    var line = cm.$foldEnd(head.line), last = cm.lastLine();
    for (var i = 1; i < motionArgs.repeat; i++) line = line < last ? cm.$foldEnd(line + 1) : line + 1;
    return new Pos(line, Infinity);
  });

  // Ex commands registered from Swift dispatch back to the editor's host.
  function defineHostEx(name, prefix) {
    Vim.defineEx(name, prefix || name, function (cm, params) {
      var payload = {
        name: name,
        argString: params.argString || "",
        args: params.args || [],
        bang: !!(params.argString && params.argString.charAt(0) == "!") || /!$/.test(params.input || ""),
        line: params.line == null ? null : params.line,
        lineEnd: params.lineEnd == null ? null : params.lineEnd
      };
      cm.$host().ex(JSON.stringify(payload));
    });
  }

  // ---------------------------------------------------------------------------
  // Registers: Vim's full set on top of codemirror-vim's RegisterController.
  //
  // Added: "* and "+ read and write the system clipboard (and 'clipboard'
  // unnamed/unnamedplus makes it the default register), "% and "# are the
  // host's file names, "= evaluates an expression, "1 also takes deletes into
  // a named register and the Vi motions (% ( ) ` / ? n N { }), read-only
  // registers refuse writes, visual P keeps the register, "1p.. pastes "2, "3,
  // :registers / :display in Vim's layout, :let @r = and :echo, <C-r> in the
  // command line. Macros are plain key text ("qp shows A!<Esc>), so a pasted,
  // edited and yanked back macro runs; replay stops at an error, or when j/k
  // can't move, as in Vim.
  // ---------------------------------------------------------------------------

  var activeCm = null;       // the editor that handles the current key
  var currentEvent = null;   // the key event being handled
  var lastExpression = "";

  function G() { return Vim.getVimGlobalState_(); }
  function clipUnnamed() {
    var v = Vim.getOption("clipboard");
    return typeof v == "string" && /(^|,)unnamed(plus)?(,|$)/.test(v);
  }
  function showMessage(cm, text, isError, long) {
    var pre = document.createElement("div");
    pre.style.whiteSpace = "pre";
    pre.setAttribute("class", "cm-vim-message");
    if (isError) pre.style.color = "red";
    pre.appendChild(document.createTextNode(long ? text + "\n" : text));
    var node = pre;
    if (long) {
      node = document.createElement("div");
      node.appendChild(pre);
      var more = document.createElement("div");
      more.appendChild(document.createTextNode("Press ENTER or type command to continue"));
      node.appendChild(more);
    }
    if (cm.state.closeVimNotification) cm.state.closeVimNotification();
    cm.state.closeVimNotification = cm.openNotification(node, { bottom: true, duration: long ? 0 : 15000 });
    if (isError && cm.$keyDepth) cm.$keyError = true;
  }

  // The system clipboard as a register. Text written from vim remembers
  // whether it was linewise; text from other apps is linewise when it ends
  // with a newline, as in Vim.
  var clipMemo = null;
  function ClipboardRegister() {
    this.keyBuffer = []; this.insertModeChanges = []; this.searchQueries = [];
  }
  ClipboardRegister.prototype.read = function () { return String(runtime.clipboardRead() || ""); };
  ClipboardRegister.prototype.setText = function (text, linewise, blockwise) {
    text = text || "";
    clipMemo = { text: text, linewise: !!linewise, blockwise: !!blockwise };
    runtime.clipboardWrite(text);
  };
  ClipboardRegister.prototype.pushText = function (text, linewise) {
    var current = this.read(), was = this.linewise;
    if (linewise && !was && current) current += "\n";
    this.setText(current + text, was || linewise);
  };
  ClipboardRegister.prototype.clear = function () { this.setText(""); };
  ClipboardRegister.prototype.pushInsertModeChanges = function () {};
  ClipboardRegister.prototype.pushSearchQuery = function () {};
  ClipboardRegister.prototype.toString = function () { return this.read(); };
  Object.defineProperty(ClipboardRegister.prototype, "linewise", {
    get: function () {
      var text = this.read();
      return clipMemo && clipMemo.text === text ? clipMemo.linewise : /\n$/.test(text);
    },
    set: function () {}
  });
  Object.defineProperty(ClipboardRegister.prototype, "blockwise", {
    get: function () { return !!(clipMemo && clipMemo.text === this.read() && clipMemo.blockwise); },
    set: function () {}
  });
  var clipboardRegister = new ClipboardRegister();

  // A register whose text comes from a function: "%, "#, "=.
  function ComputedRegister(get) {
    this.get = get; this.keyBuffer = []; this.insertModeChanges = []; this.searchQueries = [];
    this.linewise = false; this.blockwise = false;
  }
  ComputedRegister.prototype.setText = function () {};
  ComputedRegister.prototype.pushText = function () {};
  ComputedRegister.prototype.clear = function () {};
  ComputedRegister.prototype.pushInsertModeChanges = function () {};
  ComputedRegister.prototype.pushSearchQuery = function () {};
  ComputedRegister.prototype.toString = function () { return String(this.get() || ""); };
  var expressionResult = "";
  var fileRegister = new ComputedRegister(function () { return activeCm && activeCm.$fileName; });
  var altFileRegister = new ComputedRegister(function () { return activeCm && activeCm.$altFileName; });
  var expressionRegister = new ComputedRegister(function () { return expressionResult; });

  var readOnlyRegisters = ".:%#/=";
  // d or c with these motions puts even a part of a line in "1 (Vi compatible).
  var viMotionCommand = /[dc]\d*(?:[%()\/?nN{}]|`.)$/;

  // Installs everything on the current RegisterController and macro state
  // (vim.js replaces them when its global state is reset).
  function ensureRegisters() {
    var rc = Vim.getRegisterController();
    if (rc.$vimkit) return rc;
    rc.$vimkit = true;
    var Register = rc.unnamedRegister.constructor;
    rc.registers["+"] = clipboardRegister;
    rc.registers["*"] = clipboardRegister;
    rc.registers["%"] = fileRegister;
    rc.registers["#"] = altFileRegister;
    rc.registers["="] = expressionRegister;
    var history = rc.registers[":"];
    history.setText = function (text, linewise, blockwise) {
      this.$previous = this.toString();
      Register.prototype.setText.call(this, text, linewise, blockwise);
    };

    var isValid = rc.isValidRegister;
    rc.isValidRegister = function (name) {
      return isValid.call(this, name) || (typeof name == "string" && name.length == 1 && "*%#=".indexOf(name) >= 0);
    };
    var getRegister = rc.getRegister;
    rc.getRegister = function (name) {
      if ((!name || name == '"') && clipUnnamed()) return clipboardRegister;
      return getRegister.call(this, name);
    };
    var unnamed = rc.unnamedRegister;
    unnamed.setText = function (text, linewise, blockwise) {
      Register.prototype.setText.call(this, text, linewise, blockwise);
      if (!rc.$named && !rc.$keep && clipUnnamed()) clipboardRegister.setText(text, linewise, blockwise);
    };
    var pushText = rc.pushText;
    rc.pushText = function (name, operator, text, linewise, blockwise) {
      if (name && name.length == 1 && readOnlyRegisters.indexOf(name) >= 0) {
        if (activeCm) showMessage(activeCm, "E354: Invalid register name: '" + name + "'", true);
        return;
      }
      if (name === "_") return;
      if (linewise && text.charAt(text.length - 1) !== "\n") text += "\n";
      var deleting = operator == "delete" || operator == "change";
      var multiline = text.indexOf("\n") != -1;
      var vim = activeCm && activeCm.state.vim;
      var viMotion = deleting && !multiline && vim && !vim.visualMode && viMotionCommand.test(activeCm.$recentKeys || "");
      this.$named = !!name && name != '"';
      try { pushText.call(this, name == '"' ? null : name, operator, text, linewise, blockwise); }
      finally { this.$named = false; }
      if (deleting && ((this.$isNamed(name) && multiline) || viMotion)) {
        this.shiftNumericRegisters_();
        this.registers["1"] = new Register(text, linewise, blockwise);
      }
    };
    rc.$isNamed = function (name) { return !!name && name != '"'; };

    // Macros as key text.
    var mms = G().macroModeState;
    var enter = mms.enterMacroRecordMode, exit = mms.exitMacroRecordMode;
    mms.enterMacroRecordMode = function (cm, name) {
      if (!/^[0-9a-zA-Z"]$/.test(name)) return;
      var before = rc.getRegister(name).toString();
      var prefix = /[A-Z]/.test(name) ? before : "";
      enter.call(this, cm, name);
      var reg = rc.getRegister(name);
      // `before`: what @q runs while q is being recorded, as in Vim.
      if (reg instanceof Register) reg.$recording = { prefix: prefix, inserts: [], before: before };
    };
    mms.exitMacroRecordMode = function () {
      var name = this.latestRegister;
      exit.call(this);
      var reg = name && rc.getRegister(name);
      var rec = reg && reg.$recording;
      if (!rec) return;
      reg.$recording = null;
      var out = rec.prefix, k = 0, keys = reg.keyBuffer;
      for (var i = 0; i <= keys.length; i++) {
        while (k < rec.inserts.length && rec.inserts[k].at == i) out += rec.inserts[k++].text;
        if (i < keys.length) out += keys[i] == "<" ? "<lt>" : keys[i];
      }
      reg.setText(out, false, false);
      reg.insertModeChanges = [];
      reg.searchQueries = [];
    };
    var proto = Register.prototype;
    if (!proto.$vimkit) {
      proto.$vimkit = true;
      var pushChanges = proto.pushInsertModeChanges;
      proto.pushInsertModeChanges = function (changes) {
        pushChanges.call(this, changes);
        if (!this.$recording) return;
        var text = "";
        (changes.changes || []).forEach(function (c) {
          if (typeof c == "string") text += c.replace(/</g, "<lt>").replace(/\n/g, "<CR>");
          else if (c && /Backspace/.test(c.keyName)) text += "<BS>";
          else if (c && /Delete/.test(c.keyName)) text += "<Del>";
        });
        this.$recording.inserts.push({ at: this.keyBuffer.length, text: text + insertExitKey() });
      };
      var pushQuery = proto.pushSearchQuery;
      proto.pushSearchQuery = function (query) {
        if (!this.$recording) pushQuery.call(this, query); // prompt keys are recorded as keys
      };
    }
    return rc;
  }

  // The key that left insert mode while recording.
  function insertExitKey() {
    var e = currentEvent;
    if (e && e.ctrlKey && !e.altKey && !e.metaKey) {
      if (e.key == "o") return "<C-o>";
      if (e.key == "c") return "<C-c>";
      if (e.key == "[") return "<C-[>";
    }
    return "<Esc>";
  }

  function keyNotation(e) {
    var key = Vim.vimKeyFromEvent(e);
    return key == "<" ? "<lt>" : key || "";
  }

  // Keys typed into the `:` or `/` prompt while recording.
  function recordPromptKey(e) {
    var mms = G().macroModeState;
    if (!mms.isRecording || mms.isPlaying) return;
    var reg = Vim.getRegisterController().getRegister(mms.latestRegister);
    if (reg && reg.$recording) reg.keyBuffer.push(keyNotation(e));
  }

  Vim.defineAction("replayMacro", function (cm, args, vim) {
    var rc = ensureRegisters(), mms = G().macroModeState;
    var name = args.selectedCharacter || "", repeat = args.repeat || 1;
    if (name == "@") name = mms.latestRegister || "";
    else mms.latestRegister = name;
    if (name == ":") {
      var command = rc.getRegister(":").toString();
      while (command && repeat--) Vim.handleEx(cm, command);
      return;
    }
    if (!rc.isValidRegister(name)) return;
    var reg = rc.getRegister(name);
    var text = (reg.$recording ? reg.$recording.before : reg.toString()).replace(/\x1b/g, "<Esc>").replace(/\r/g, "<CR>");
    if (!text) return;
    if ((cm.$macroDepth || 0) >= 100) {
      showMessage(cm, "E169: Command too recursive", true);
      return;
    }
    var tokens = tokenizeKeys(text), playing = mms.isPlaying;
    // The whole macro is one change for u, as in Vim.
    var history = cm.history, outer = !cm.$macroDepth, mark = 0;
    if (outer) { history.close(); mark = history.done.length; }
    cm.$macroDepth = (cm.$macroDepth || 0) + 1;
    // The keys run as if typed (search prompts, insert-mode changes and `.`
    // work as in Vim); while recording, they must not be recorded again.
    mms.isPlaying = !!mms.isRecording;
    try {
      play: while (repeat--) {
        for (var i = 0; i < tokens.length; i++) {
          if (!cm.$playMacroKey(tokens[i])) break play;
        }
      }
    } finally {
      mms.isPlaying = playing;
      cm.$macroDepth--;
      if (outer && !vim.insertMode) {
        history.close();
        mark = Math.min(mark, history.done.length);
        var groups = history.done.splice(mark);
        if (groups.length) {
          var merged = { changes: [], selBefore: groups[0].selBefore };
          groups.forEach(function (g) { merged.changes = merged.changes.concat(g.changes); });
          history.done.push(merged);
        }
      }
    }
  });

  var verticalKeys = { j: 1, k: 1, "+": 1, "-": 1, "<CR>": 1, "<Down>": 1, "<Up>": 1, "<C-n>": 1, "<C-p>": 1, "<C-j>": 1 };
  // Plays one key of a macro; false stops the macro (an error, or a line
  // motion that could not move).
  proto.$playMacroKey = function (token) {
    var vim = this.state.vim, note = this.notification;
    var line = -1;
    if (verticalKeys[token] && vim && !vim.insertMode && !this.dialog && !vim.inputState.operator) {
      line = this.getCursor().line;
    }
    var e = eventFromNotation(token), raw = this.$macroKeys;
    this.$macroKeys = true;
    this.$macroFailed = false;
    try { if (!this.handleKeyEvent(e)) this.$defaultInput(e); }
    finally { this.$macroKeys = raw; }
    // The macro runs inside one vim operation; deliver this key's changes
    // now, as a typed key would, so insert-mode changes and `.` see them.
    var op = this.curOp;
    if (op && op.change) {
      var change = op.change, handlers = op.changeHandlers;
      op.change = op.lastChange = null;
      op.changeHandlers = null;
      signalTo(handlers, this, change);
    }
    if (this.notification && this.notification !== note && this.notification.isError) return false;
    if (line >= 0 && this.getCursor().line == line && !vim.inputState.operator) return false;
    return !this.$macroFailed;
  };

  // Visual-mode P: like p, but the register keeps its text.
  Vim.defineAction("vimkitPasteKeep", function (cm, args, vim) {
    var rc = ensureRegisters(), u = rc.unnamedRegister;
    var saved = [u.keyBuffer.slice(), u.linewise, u.blockwise];
    rc.$keep = true;
    try {
      vim.inputState.registerName = args.registerName;
      if (args.repeatIsExplicit && args.repeat > 1) Vim.handleKey(cm, String(args.repeat), "mapping");
      Vim.handleKey(cm, "p", "mapping");
    } finally {
      u.keyBuffer = saved[0]; u.linewise = saved[1]; u.blockwise = saved[2];
      rc.$keep = false;
    }
  });
  Vim.mapCommand("P", "action", "vimkitPasteKeep", { after: false, isEdit: true }, { context: "visual" });

  // "= in normal/visual mode and <C-r>= in insert mode ask for an expression.
  function promptExpression(cm, done) {
    var tpl = document.createElement("div");
    tpl.appendChild(document.createTextNode("="));
    var input = document.createElement("input");
    tpl.appendChild(input);
    cm.openDialog(tpl, function (value) {
      var source = value || lastExpression;
      if (!source) return;
      lastExpression = source;
      try { expressionResult = evaluate(cm, source).text(); }
      catch (err) { showMessage(cm, String(err.message || err), true); return; }
      done(expressionResult);
    }, { bottom: true });
  }
  Vim.defineAction("setRegister", function (cm, args, vim) {
    var name = args.selectedCharacter;
    if (name != "=") { vim.inputState.registerName = name; return; }
    promptExpression(cm, function () { vim.inputState.registerName = "="; });
  });
  Vim.defineAction("insertRegister", function (cm, args, vim) {
    var name = args.selectedCharacter;
    if (name == "=") {
      promptExpression(cm, function (text) { if (text) cm.replaceSelection(text); });
      return;
    }
    var rc = ensureRegisters();
    if (!rc.isValidRegister(name)) return;
    var text = rc.getRegister(name).toString();
    if (text) cm.replaceSelection(text);
  });

  // "1p followed by . pastes "2, then "3 ...
  function bumpNumberedPaste(vim) {
    var input = vim.lastEditInputState, command = vim.lastEditActionCommand;
    if (!input || !command || command.action != "paste") return;
    var name = input.registerName;
    if (/^[1-8]$/.test(name || "")) input.registerName = String(+name + 1);
  }

  // :registers / :display
  var registerOrder = '"0123456789abcdefghijklmnopqrstuvwxyz-.:%#/=*+';
  function displayText(text) {
    var out = "";
    for (var i = 0; i < text.length && out.length < 200; i++) {
      var c = text.charCodeAt(i);
      out += c < 32 ? "^" + String.fromCharCode(c + 64) : c == 127 ? "^?" : text.charAt(i);
    }
    return out;
  }
  function listRegisters(cm, params) {
    var rc = ensureRegisters();
    // Like vim.js's own :registers, it is not remembered in ":.
    var history = rc.registers[":"];
    if (history.$previous != null && history.toString() == params.input) history.setText(history.$previous);
    var wanted = params.args ? params.args.join("").replace(/\s/g, "") : "";
    var lines = ["Type Name Content"];
    for (var i = 0; i < registerOrder.length; i++) {
      var name = registerOrder.charAt(i);
      if (wanted && wanted.indexOf(name) < 0 && wanted.indexOf(name.toUpperCase()) < 0) continue;
      var reg = name == '"' ? rc.unnamedRegister : rc.registers[name];
      if (name == '"' && clipUnnamed()) reg = clipboardRegister;
      if (!reg) continue;
      var text = reg.toString();
      if (!text) continue;
      var type = reg.blockwise ? "b" : reg.linewise ? "l" : "c";
      lines.push("  " + type + "  \"" + name + "   " + displayText(text));
    }
    showMessage(cm, lines.join("\n"), false, true);
  }
  Vim.defineEx("registers", "reg", listRegisters);
  Vim.defineEx("display", "di", listRegisters);

  // :let @r = expr, :let @r .= expr, :let &option = expr
  Vim.defineEx("let", "let", function (cm, params) {
    var m = /^\s*(@.|&\w+)\s*(\.\.?=|\+=|-=|=)\s*([\s\S]*)$/.exec(params.argString || "");
    if (!m) {
      showMessage(cm, "E121: Undefined variable: " + String(params.argString || "").trim(), true);
      return;
    }
    var value;
    try { value = evaluate(cm, m[3]); }
    catch (err) { showMessage(cm, String(err.message || err), true); return; }
    var target = m[1], op = m[2];
    if (target.charAt(0) == "&") {
      var opt = target.slice(1);
      var cur = Vim.getOption(opt, cm);
      if (cur instanceof Error) { showMessage(cm, "E355: Unknown option: " + opt, true); return; }
      var v = typeof cur == "number" || typeof cur == "boolean" ? value.num() : value.text();
      if (op == "+=") v = (+cur || 0) + value.num();
      else if (op == "-=") v = (+cur || 0) - value.num();
      else if (op != "=") v = String(cur) + value.text();
      Vim.setOption(opt, typeof cur == "boolean" ? !!v : v, cm);
      return;
    }
    var name = target.charAt(1), rc = ensureRegisters();
    if (name == "_") return;
    if (name == "/") {
      setSearchPattern(cm, value.text());
      return;
    }
    if (".:%#=".indexOf(name) >= 0) { showMessage(cm, "E354: Invalid register name: '" + name + "'", true); return; }
    var text = value.text();
    if (op != "=" || /[A-Z]/.test(name)) text = rc.getRegister(name).toString() + text;
    var reg = name == '"' ? rc.unnamedRegister : rc.getRegister(name.toLowerCase());
    var linewise = /\n$/.test(text);
    reg.setText(text, linewise);
  });

  Vim.defineEx("echo", "ec", function (cm, params) {
    var src = String(params.argString || "").trim();
    if (!src) return;
    try { showMessage(cm, evaluateList(cm, src).join(" "), false); }
    catch (err) { showMessage(cm, String(err.message || err), true); }
  });

  // @/ = pattern: the next n and the highlight use it; the cursor stays.
  function setSearchPattern(cm, pattern) {
    var rc = ensureRegisters();
    rc.getRegister("/").setText(pattern);
    Vim.handleEx(cm, "nohlsearch"); // creates the search state
    var re;
    try { re = vimPatternToRegExp(pattern); }
    catch (err) { showMessage(cm, "E486: Pattern not found: " + pattern, true); return; }
    G().query = re;
    var state = cm.state.vim && cm.state.vim.searchState_;
    var overlay = { query: re, token: function () {} };
    if (state) state.setOverlay(overlay);
    cm.addOverlay(overlay);
  }
  // Vim's magic pattern syntax in a JavaScript RegExp (the common subset).
  function vimPatternToRegExp(p) {
    var out = "", ignoreCase = Vim.getOption("ignorecase") === true;
    if (ignoreCase && Vim.getOption("smartcase") === true && /[A-Z]/.test(p)) ignoreCase = false;
    for (var i = 0; i < p.length; i++) {
      var c = p.charAt(i);
      if (c == "\\" && i + 1 < p.length) {
        var n = p.charAt(++i);
        if (n == "<" || n == ">") out += "\\b";
        else if ("(){}|+=?".indexOf(n) >= 0) out += n == "=" ? "?" : n;
        else if (n == "c") ignoreCase = true;
        else if (n == "C") ignoreCase = false;
        else out += "\\" + n;
      } else if ("(){}|+?".indexOf(c) >= 0) out += "\\" + c;
      else out += c;
    }
    return new RegExp(out, ignoreCase ? "im" : "m");
  }

  // ---- expressions ---------------------------------------------------------
  // A subset of Vim script expressions: numbers, floats, 'strings' and
  // "strings", @r, &option, + - * / %, . and .. (concatenation), comparisons
  // (== != > >= < <= =~ !~, # and ? variants), && || ! ?:, and the functions
  // in exprFunctions.
  function Val(v) { this.v = v; }
  Val.prototype.isStr = function () { return typeof this.v == "string"; };
  Val.prototype.num = function () {
    if (typeof this.v == "number") return this.v;
    var m = /^\s*([-+]?)(0[xX][0-9a-fA-F]+|\d+)/.exec(this.v);
    if (!m) return 0;
    var n = /^0[xX]/.test(m[2]) ? parseInt(m[2], 16) : parseInt(m[2], 10);
    return m[1] == "-" ? -n : n;
  };
  Val.prototype.text = function () {
    if (typeof this.v == "string") return this.v;
    if (this.isFloat) {
      if (!isFinite(this.v)) return this.v > 0 ? "inf" : this.v < 0 ? "-inf" : "nan";
      var s = String(+this.v.toPrecision(6));
      return /[.e]/.test(s) ? s : s + ".0";
    }
    return String(this.v);
  };
  function num(n, isFloat) { var v = new Val(n); v.isFloat = !!isFloat; return v; }
  function str(s) { return new Val(String(s)); }

  function pad(n, w) { n = String(n); while (n.length < w) n = "0" + n; return n; }
  var dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December"];
  function strftime(fmt, d) {
    return fmt.replace(/%([a-zA-Z%])/g, function (_, c) {
      var h = d.getHours();
      switch (c) {
        case "Y": return String(d.getFullYear());
        case "y": return pad(d.getFullYear() % 100, 2);
        case "m": return pad(d.getMonth() + 1, 2);
        case "d": return pad(d.getDate(), 2);
        case "e": return (d.getDate() < 10 ? " " : "") + d.getDate();
        case "H": return pad(h, 2);
        case "I": return pad(h % 12 || 12, 2);
        case "M": return pad(d.getMinutes(), 2);
        case "S": return pad(d.getSeconds(), 2);
        case "p": return h < 12 ? "AM" : "PM";
        case "a": return dayNames[d.getDay()].slice(0, 3);
        case "A": return dayNames[d.getDay()];
        case "b": case "h": return monthNames[d.getMonth()].slice(0, 3);
        case "B": return monthNames[d.getMonth()];
        case "j": return pad(Math.floor((d - new Date(d.getFullYear(), 0, 1)) / 864e5) + 1, 3);
        case "u": return String(d.getDay() || 7);
        case "w": return String(d.getDay());
        case "F": return d.getFullYear() + "-" + pad(d.getMonth() + 1, 2) + "-" + pad(d.getDate(), 2);
        case "T": return pad(h, 2) + ":" + pad(d.getMinutes(), 2) + ":" + pad(d.getSeconds(), 2);
        case "D": return pad(d.getMonth() + 1, 2) + "/" + pad(d.getDate(), 2) + "/" + pad(d.getFullYear() % 100, 2);
        case "z":
          var o = -d.getTimezoneOffset();
          return (o < 0 ? "-" : "+") + pad(Math.floor(Math.abs(o) / 60), 2) + pad(Math.abs(o) % 60, 2);
        case "s": return String(Math.floor(d.getTime() / 1000));
        case "n": return "\n";
        case "t": return "\t";
        case "%": return "%";
        default: return "%" + c;
      }
    });
  }
  function lineArg(cm, v) {
    var s = v.text();
    if (s == ".") return cm.getCursor().line;
    if (s == "$") return cm.lastLine();
    if (s == "w0" || s == "w$") return s == "w0" ? 0 : cm.lastLine();
    if (/^'.$/.test(s)) {
      var mark = cm.state.vim && cm.state.vim.marks[s.charAt(1)];
      var pos = mark && mark.find();
      return pos ? pos.line : -1;
    }
    return v.num() - 1;
  }
  function expandArg(cm, s) {
    var m = /^(%|#|<cword>|<cWORD>)((?::[phtre])*)$/.exec(s);
    if (!m) return s;
    var v;
    if (m[1] == "%") v = cm.$fileName || "";
    else if (m[1] == "#") v = cm.$altFileName || "";
    else {
      var cur = cm.getCursor(), line = cm.getLine(cur.line);
      var re = m[1] == "<cword>" ? /[\wÀ-￿]/ : /\S/;
      var a = cur.ch, b = cur.ch;
      while (a > 0 && re.test(line.charAt(a - 1))) a--;
      while (b < line.length && re.test(line.charAt(b))) b++;
      v = line.slice(a, b);
    }
    m[2].split(":").slice(1).forEach(function (mod) {
      if (mod == "t") v = v.replace(/^.*\//, "");
      else if (mod == "h") v = v.indexOf("/") >= 0 ? v.replace(/\/[^\/]*$/, "") || "/" : ".";
      else if (mod == "r") v = v.replace(/\.[^.\/]*$/, "");
      else if (mod == "e") { var e = /\.([^.\/]*)$/.exec(v); v = e ? e[1] : ""; }
    });
    return v;
  }
  function printf(args) {
    var fmt = args[0] ? args[0].text() : "", k = 1;
    return fmt.replace(/%([-0 +#]*)(\d*)(?:\.(\d+))?([diouxXscfeEgG%])/g, function (all, flags, width, prec, conv) {
      if (conv == "%") return "%";
      var a = args[k++] || str("");
      var s;
      switch (conv) {
        case "d": case "i": case "u": s = String(Math.trunc(a.num())); break;
        case "o": s = Math.trunc(a.num()).toString(8); break;
        case "x": s = Math.trunc(a.num()).toString(16); break;
        case "X": s = Math.trunc(a.num()).toString(16).toUpperCase(); break;
        case "c": s = String.fromCharCode(a.num()); break;
        case "s": s = a.text(); if (prec) s = s.slice(0, +prec); break;
        case "f": s = (typeof a.v == "number" ? a.v : a.num()).toFixed(prec ? +prec : 6); break;
        case "e": case "E": s = (+a.v || a.num()).toExponential(prec ? +prec : 6); if (conv == "E") s = s.toUpperCase(); break;
        default: s = String(+(+a.v || a.num()).toPrecision(prec ? +prec : 6));
      }
      if (/\+/.test(flags) && /[dif]/.test(conv) && s.charAt(0) != "-") s = "+" + s;
      var w = +width || 0;
      if (s.length < w) {
        if (/-/.test(flags)) while (s.length < w) s += " ";
        else if (/0/.test(flags) && conv != "s") { var neg = s.charAt(0) == "-" || s.charAt(0) == "+" ? s.charAt(0) : ""; s = s.slice(neg.length); while (s.length + neg.length < w) s = "0" + s; s = neg + s; }
        else while (s.length < w) s = " " + s;
      }
      return s;
    });
  }
  var exprFunctions = {
    strlen: function (cm, a) { return num(a[0].text().length); },
    len: function (cm, a) { return num(a[0].text().length); },
    strchars: function (cm, a) { return num(Array.from(a[0].text()).length); },
    toupper: function (cm, a) { return str(a[0].text().toUpperCase()); },
    tolower: function (cm, a) { return str(a[0].text().toLowerCase()); },
    repeat: function (cm, a) { var n = a[1].num(); return str(n > 0 ? new Array(n + 1).join(a[0].text()) : ""); },
    trim: function (cm, a) { return str(a[0].text().trim()); },
    string: function (cm, a) { return str(a[0].isStr() ? "'" + a[0].v.replace(/'/g, "''") + "'" : a[0].text()); },
    str2nr: function (cm, a) { return num(a[1] ? parseInt(a[0].text(), a[1].num()) || 0 : a[0].num()); },
    str2float: function (cm, a) { return num(parseFloat(a[0].text()) || 0, true); },
    float2nr: function (cm, a) { return num(Math.trunc(+a[0].v || a[0].num())); },
    abs: function (cm, a) { var v = a[0]; return num(Math.abs(typeof v.v == "number" ? v.v : v.num()), v.isFloat); },
    round: function (cm, a) { return num(Math.round(+a[0].v || a[0].num()), true); },
    floor: function (cm, a) { return num(Math.floor(+a[0].v || a[0].num()), true); },
    ceil: function (cm, a) { return num(Math.ceil(+a[0].v || a[0].num()), true); },
    sqrt: function (cm, a) { return num(Math.sqrt(+a[0].v || a[0].num()), true); },
    pow: function (cm, a) { return num(Math.pow(+a[0].v || a[0].num(), +a[1].v || a[1].num()), true); },
    line: function (cm, a) { var l = lineArg(cm, a[0]); return num(l < 0 ? 0 : l + 1); },
    col: function (cm, a) {
      var s = a[0].text();
      if (s == "$") return num(cm.getLine(cm.getCursor().line).length + 1);
      return num(cm.getCursor().ch + 1);
    },
    getline: function (cm, a) { var l = lineArg(cm, a[0]); return str(l >= 0 && l <= cm.lastLine() ? cm.getLine(l) : ""); },
    expand: function (cm, a) { return str(expandArg(cm, a[0].text())); },
    localtime: function () { return num(Math.floor(Date.now() / 1000)); },
    strftime: function (cm, a) { return str(strftime(a[0].text(), a[1] ? new Date(a[1].num() * 1000) : new Date())); },
    printf: function (cm, a) { return str(printf(a)); },
    substitute: function (cm, a) {
      var re = vimPatternToRegExp(a[1].text());
      var flags = a[3] ? a[3].text() : "";
      re = new RegExp(re.source, re.flags.replace("m", "") + (flags.indexOf("g") >= 0 ? "g" : ""));
      var rep = a[2].text().replace(/\\(\d)/g, "$$$1").replace(/&/g, "$$&");
      return str(a[0].text().replace(re, rep));
    },
    matchstr: function (cm, a) { var m = vimPatternToRegExp(a[1].text()).exec(a[0].text()); return str(m ? m[0] : ""); },
    escape: function (cm, a) {
      var chars = a[1].text();
      return str(a[0].text().replace(/[\s\S]/g, function (c) { return chars.indexOf(c) >= 0 ? "\\" + c : c; }));
    },
    getreg: function (cm, a) { return str(ensureRegisters().getRegister(a[0] ? a[0].text() : '"').toString()); },
    nr2char: function (cm, a) { return str(String.fromCodePoint(a[0].num())); },
    char2nr: function (cm, a) { var s = a[0].text(); return num(s ? s.codePointAt(0) : 0); }
  };

  function tokenizeExpr(src) {
    var re = /\s*(?:(0[xX][0-9a-fA-F]+|\d+\.\d+(?:[eE][-+]?\d+)?|\d+)|('(?:[^']|'')*')|("(?:[^"\\]|\\.)*")|(@.)|(&\w+)|([a-zA-Z_][\w:]*)|(\.\.|==[#?]?|!=[#?]?|>=[#?]?|<=[#?]?|=~[#?]?|!~[#?]?|&&|\|\||[-+*\/%.<>!?:(),]))/y;
    var out = [], m;
    re.lastIndex = 0;
    while (re.lastIndex < src.length) {
      var at = re.lastIndex;
      if (/^\s*$/.test(src.slice(at))) break;
      m = re.exec(src);
      if (!m) throw new Error("E15: Invalid expression: \"" + src.slice(at).trim() + "\"");
      if (m[1]) out.push({ t: "num", v: m[1] });
      else if (m[2]) out.push({ t: "str", v: m[2].slice(1, -1).replace(/''/g, "'") });
      else if (m[3]) out.push({ t: "str", v: unescapeDouble(m[3].slice(1, -1)) });
      else if (m[4]) out.push({ t: "reg", v: m[4].charAt(1) });
      else if (m[5]) out.push({ t: "opt", v: m[5].slice(1) });
      else if (m[6]) out.push({ t: "name", v: m[6] });
      else out.push({ t: "op", v: m[7] });
    }
    return out;
  }
  function unescapeDouble(s) {
    return s.replace(/\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|<[^>]+>|[\s\S])/g, function (_, e) {
      switch (e.charAt(0)) {
        case "n": return e.length == 1 ? "\n" : e;
        case "t": return "\t";
        case "r": return "\r";
        case "e": return "\x1b";
        case "x": case "u": return String.fromCharCode(parseInt(e.slice(1), 16));
        case "<": return e;
        default: return e;
      }
    });
  }

  function Parser(cm, src) { this.cm = cm; this.src = src; this.toks = tokenizeExpr(src); this.i = 0; }
  Parser.prototype.peek = function () { return this.toks[this.i]; };
  Parser.prototype.isOp = function (v) { var t = this.toks[this.i]; return t && t.t == "op" && t.v == v; };
  Parser.prototype.fail = function () {
    throw new Error("E15: Invalid expression: \"" + this.src.trim() + "\"");
  };
  Parser.prototype.expect = function (v) { if (!this.isOp(v)) this.fail(); this.i++; };
  Parser.prototype.expr = function () {
    var c = this.or();
    if (this.isOp("?")) {
      this.i++;
      var a = this.expr();
      this.expect(":");
      var b = this.expr();
      return truthy(c) ? a : b;
    }
    return c;
  };
  function truthy(v) { return v.isStr() ? v.num() != 0 : v.v != 0; }
  Parser.prototype.or = function () {
    var a = this.and();
    while (this.isOp("||")) { this.i++; var b = this.and(); a = num(truthy(a) || truthy(b) ? 1 : 0); }
    return a;
  };
  Parser.prototype.and = function () {
    var a = this.cmp();
    while (this.isOp("&&")) { this.i++; var b = this.cmp(); a = num(truthy(a) && truthy(b) ? 1 : 0); }
    return a;
  };
  Parser.prototype.cmp = function () {
    var a = this.add(), t = this.peek();
    if (t && t.t == "op" && /^(==|!=|>=?|<=?|=~|!~)[#?]?$/.test(t.v)) {
      this.i++;
      var b = this.add(), op = t.v.replace(/[#?]$/, "");
      var ic = /\?$/.test(t.v) || (!/#$/.test(t.v) && Vim.getOption("ignorecase") === true);
      var r;
      if (op == "=~" || op == "!~") {
        var re = vimPatternToRegExp(b.text());
        if (ic) re = new RegExp(re.source, "im");
        r = re.test(a.text()) == (op == "=~");
      } else {
        var x, y;
        if (a.isStr() && b.isStr()) { x = a.v; y = b.v; if (ic) { x = x.toLowerCase(); y = y.toLowerCase(); } }
        else { x = typeof a.v == "number" ? a.v : a.num(); y = typeof b.v == "number" ? b.v : b.num(); }
        r = op == "==" ? x == y : op == "!=" ? x != y : op == ">" ? x > y : op == ">=" ? x >= y : op == "<" ? x < y : x <= y;
      }
      return num(r ? 1 : 0);
    }
    return a;
  };
  Parser.prototype.add = function () {
    var a = this.mul();
    for (;;) {
      var t = this.peek();
      if (!t || t.t != "op" || !/^(\+|-|\.|\.\.)$/.test(t.v)) return a;
      this.i++;
      var b = this.mul();
      if (t.v == "." || t.v == "..") { a = str(a.text() + b.text()); continue; }
      var f = a.isFloat || b.isFloat;
      var x = f ? +a.v || a.num() : a.num(), y = f ? +b.v || b.num() : b.num();
      a = num(t.v == "+" ? x + y : x - y, f);
    }
  };
  Parser.prototype.mul = function () {
    var a = this.unary();
    for (;;) {
      var t = this.peek();
      if (!t || t.t != "op" || !/^[*\/%]$/.test(t.v)) return a;
      this.i++;
      var b = this.unary();
      var f = a.isFloat || b.isFloat;
      var x = f ? +a.v || a.num() : a.num(), y = f ? +b.v || b.num() : b.num();
      if (t.v == "*") a = num(x * y, f);
      else if (t.v == "%") { if (f) throw new Error("E804: Cannot use '%' with Float"); a = num(y == 0 ? 0 : x % y); }
      else if (f) a = num(x / y, true);
      else if (y == 0) throw new Error("E1154: Divide by zero");
      else a = num(Math.trunc(x / y));
    }
  };
  Parser.prototype.unary = function () {
    if (this.isOp("-")) { this.i++; var v = this.unary(); return num(-(v.isFloat ? v.v : v.num()), v.isFloat); }
    if (this.isOp("+")) { this.i++; var w = this.unary(); return num(w.isFloat ? w.v : w.num(), w.isFloat); }
    if (this.isOp("!")) { this.i++; return num(truthy(this.unary()) ? 0 : 1); }
    return this.primary();
  };
  Parser.prototype.primary = function () {
    var t = this.toks[this.i++];
    if (!t) this.fail();
    if (t.t == "num") return /[.eE]/.test(t.v) && !/^0[xX]/.test(t.v) ? num(parseFloat(t.v), true) : num(/^0[xX]/.test(t.v) ? parseInt(t.v, 16) : parseInt(t.v, 10));
    if (t.t == "str") return str(t.v);
    if (t.t == "reg") return str(ensureRegisters().getRegister(t.v).toString());
    if (t.t == "opt") {
      var o = Vim.getOption(t.v, this.cm);
      if (o instanceof Error || o === undefined) o = this.cm.getOption(t.v);
      if (o === undefined) throw new Error("E113: Unknown option: " + t.v);
      return typeof o == "boolean" ? num(o ? 1 : 0) : typeof o == "number" ? num(o) : str(o);
    }
    if (t.t == "name") {
      if (t.v == "v:true") return num(1);
      if (t.v == "v:false") return num(0);
      if (!this.isOp("(")) throw new Error("E121: Undefined variable: " + t.v);
      this.i++;
      var args = [];
      if (!this.isOp(")")) {
        args.push(this.expr());
        while (this.isOp(",")) { this.i++; args.push(this.expr()); }
      }
      this.expect(")");
      var fn = exprFunctions[t.v];
      if (!fn) throw new Error("E117: Unknown function: " + t.v);
      return fn(this.cm, args);
    }
    if (t.t == "op" && t.v == "(") { var v = this.expr(); this.expect(")"); return v; }
    this.i--;
    this.fail();
  };
  function evaluate(cm, src) {
    var p = new Parser(cm, src);
    var v = p.expr();
    if (p.i < p.toks.length) p.fail();
    return v;
  }
  function evaluateList(cm, src) {
    var p = new Parser(cm, src), out = [];
    while (p.i < p.toks.length) out.push(p.expr().text());
    return out;
  }

  // ---- options the host shows: number, relativenumber, numberwidth ----------
  var hostOptionValues = {};
  function defineHostOption(name, aliases, type, def) {
    Vim.defineOption(name, undefined, type, aliases, function (value, cm) {
      if (cm === undefined) {
        if (value === undefined) return name in hostOptionValues ? hostOptionValues[name] : def;
        hostOptionValues[name] = value;
        return;
      }
      var local = cm.$vimOptions || (cm.$vimOptions = {});
      if (value === undefined) return local[name];
      local[name] = value;
      if (cm.$host) cm.$host().event("option", name);
    });
  }
  defineHostOption("number", ["nu"], "boolean", false);
  defineHostOption("relativenumber", ["rnu"], "boolean", false);
  defineHostOption("numberwidth", ["nuw"], "number", 4);
  defineHostOption("cursorline", ["cul"], "boolean", false);
  defineHostOption("cursorlineopt", ["culopt"], "string", "both");
  Vim.defineOption("clipboard", "", "string", ["cb"]);
  // Patterns are Vim regular expressions (\(\), \+, \<, \v), not JavaScript ones.
  Vim.setOption("pcre", false);

  // vim.js's action, motion and operator tables. vim.js calls their entries
  // as methods (`actions[name](...)`), so a probe entry sees the table as
  // `this`; wrapping an entry fixes vim.js's behaviour without editing it.
  var vimActions = null, vimMotions = null, vimOperators = null;
  Vim.defineAction("vimkitTables", function () { vimActions = this; });
  Vim.defineMotion("vimkitTables", function (cm, head) { vimMotions = this; return head; });
  Vim.defineOperator("vimkitTables", function () { vimOperators = this; });
  Vim._mapCommand({ keys: "<VimKitTablesA>", type: "action", action: "vimkitTables" });
  Vim._mapCommand({ keys: "<VimKitTablesO>", type: "operatorMotion", operator: "vimkitTables", motion: "vimkitTables" });
  function captureTables(cm) {
    if (vimActions) return;
    Vim.handleKey(cm, "<VimKitTablesA>", "mapping");
    Vim.handleKey(cm, "<VimKitTablesO>", "mapping");
    if (vimActions && vimOperators) wrapVimTables();
  }

  function wrapVimTables() {
    // P (and p) leave the cursor on the last pasted character, as in Vim;
    // vim.js puts it one past for a characterwise P.
    var paste = vimActions.paste;
    vimActions.paste = function (cm, args, vim) {
      var visual = vim.visualMode, before = cm.getCursor();
      var reg = Vim.getRegisterController().getRegister(args.registerName);
      var text = reg ? reg.toString() : "";
      var result = paste.apply(this, arguments);
      if (!args.after && !visual && text && reg && !reg.linewise && !reg.blockwise && !/\n/.test(text)) {
        var cur = cm.getCursor();
        if (cur.line == before.line && cur.ch > before.ch) cm.setCursor(cur.line, cur.ch - 1);
      }
      return result;
    };

    // <C-v>I / <C-v>A: remember the top left of the block for the cursor.
    var enterInsertMode = vimActions.enterInsertMode;
    vimActions.enterInsertMode = function (cm, actionArgs, vim) {
      var start = null;
      if (vim.visualBlock) {
        start = new Pos(Math.min(vim.sel.anchor.line, vim.sel.head.line), Math.min(vim.sel.anchor.ch, vim.sel.head.ch));
      }
      var result = enterInsertMode.apply(this, arguments);
      if (start) cm.$blockInsertStart = start;
      return result;
    };

    // A characterwise visual selection whose last character is the line
    // break (v$, vi{) reaches one past the line; operators take the line
    // break with it, as in Vim.
    Object.keys(vimOperators).forEach(function (name) {
      var operator = vimOperators[name];
      if (typeof operator != "function") return;
      vimOperators[name] = function (cm, args, ranges) {
        var vim = cm.state.vim;
        if (vim && vim.visualBlock && ranges && (name == "yank" || name == "delete" || name == "change")) {
          return withBlockPadding(cm, vim, ranges, operator, this, arguments);
        }
        if (vim && vim.visualMode && !vim.visualLine && !vim.visualBlock && ranges) {
          var past = function (p) {
            return p.line < cm.lastLine() && p.ch == cm.getLine(p.line).length + 1 ? new Pos(p.line + 1, 0) : p;
          };
          var wide = ranges.map(function (r) { return { anchor: past(r.anchor), head: past(r.head) }; });
          if (wide.some(function (r, i) { return r.head != ranges[i].head || r.anchor != ranges[i].anchor; })) {
            arguments[2] = wide;
            cm.setSelections(wide, 0);
          }
        }
        return operator.apply(this, arguments);
      };
    });

    // Text objects: quotes, bracket counts and linewise blocks as in Vim.
    var textObject = vimMotions.textObjectManipulation;
    var brackets = { "(": 1, ")": 1, b: 1, "{": 1, "}": 1, B: 1, "[": 1, "]": 1, "<": 1, ">": 1 };
    vimMotions.textObjectManipulation = function (cm, head, motionArgs, vim) {
      var ch = motionArgs.selectedCharacter, inner = !!motionArgs.textObjectInner;
      if (ch == '"' || ch == "'" || ch == "`") {
        var q = quoteObject(cm, head, ch, inner, motionArgs.repeat || 1);
        if (!q) return null;
        if (!vim.visualMode) return [q.start, q.end];
        var a = cm.getCursor("anchor"), h = cm.getCursor("head");
        if (a.line == h.line && Math.abs(a.ch - h.ch) <= 1) return [q.start, new Pos(q.end.line, Math.max(q.end.ch - 1, q.start.ch))];
        return textObject.apply(this, arguments);
      }
      // A fresh visual selection (vi{) takes the same range as an operator.
      var fresh = false;
      if (brackets[ch] && inner && vim.visualMode && !vim.visualLine && !vim.visualBlock) {
        var sa = cm.getCursor("anchor"), sh = cm.getCursor("head");
        fresh = sa.line == sh.line && Math.abs(sa.ch - sh.ch) <= 1;
      }
      if (fresh) {
        vim.visualMode = false;
        try { var range = vimMotions.textObjectManipulation.call(this, cm, head, motionArgs, vim); }
        finally { vim.visualMode = true; }
        var whole = motionArgs.linewise;
        motionArgs.linewise = false;
        if (!range) return null;
        // Whole lines end on the last line break; otherwise the selection
        // ends on the last character of the range.
        var last = range[1];
        if (!whole && cm.indexFromPos(last) > cm.indexFromPos(range[0]))
          last = cm.posFromIndex(cm.indexFromPos(last) - 1);
        return [range[0], last];
      }
      var result = textObject.apply(this, arguments);
      if (!brackets[ch] || !result || vim.visualMode) return result;
      // [count]i( / [count]a(: the count-th enclosing pair.
      for (var k = 1; k < (motionArgs.repeat || 1); k++) {
        var open = cm.indexFromPos(result[0]) - (inner ? 2 : 1);
        if (open < 0) break;
        var outer = textObject.call(this, cm, cm.posFromIndex(open), motionArgs, vim);
        if (!outer || cm.indexFromPos(outer[0]) >= cm.indexFromPos(result[0])) break;
        result = outer;
      }
      if (!inner) return result;
      // i{ leaves out the line break after the opening bracket and the indent
      // before the closing one; spanning whole lines, it is linewise.
      var start = result[0], end = result[1];
      if (start.ch == cm.getLine(start.line).length && start.line < end.line) start = new Pos(start.line + 1, 0);
      if (end.line > start.line && /^[ \t]*$/.test(cm.getLine(end.line).slice(0, end.ch))) end = new Pos(end.line, 0);
      if (start.ch == 0 && end.ch == 0 && end.line > start.line) {
        motionArgs.linewise = true;
        var operatorArgs = vim.inputState.operatorArgs;
        if (operatorArgs) operatorArgs.linewise = true;
        return [start, new Pos(end.line - 1, cm.getLine(end.line - 1).length)];
      }
      return [start, end];
    };

    // In a macro, a character motion that cannot move (h in column 0, l on
    // the last character, f or ; that finds nothing) stops it, as in Vim.
    var byCharacters = vimMotions.moveByCharacters;
    vimMotions.moveByCharacters = function (cm, head, motionArgs) {
      if (cm.$macroDepth) {
        var len = cm.getLine(head.line).length, vim = cm.state.vim;
        var operator = vim && vim.inputState.operator;
        if (motionArgs.forward ? !operator && head.ch >= len - 1 : head.ch == 0) cm.$macroFailed = true;
      }
      return byCharacters.apply(this, arguments);
    };
    ["moveToCharacter", "repeatLastCharacterSearch"].forEach(function (name) {
      var motion = vimMotions[name];
      vimMotions[name] = function (cm, head, motionArgs) {
        var result = motion.apply(this, arguments);
        var last = G().lastCharacterSearch;
        var till = name == "repeatLastCharacterSearch" && last && last.increment;
        if (cm.$macroDepth && !till && result && result.line == head.line && result.ch == head.ch) cm.$macroFailed = true;
        return result;
      };
    });

    // Search motions (/, ?, n, N) apply the offset of the last search.
    var findNext = vimMotions.findNext;
    vimMotions.findNext = function (cm, head, motionArgs) {
      var result = findNext.apply(this, arguments);
      if (result && searchOffset && searchOffset.kind == "end") result = endOffsetMatch(cm, result, motionArgs);
      return applySearchOffset(cm, result, motionArgs);
    };

    // r<CR> ends like typing <CR><Esc>: the cursor before the new indent.
    var replace = vimActions.replace;
    vimActions.replace = function (cm, args, vim) {
      var result = replace.apply(this, arguments);
      if (args.selectedCharacter == "\n" && !vim.visualMode) {
        var cur = cm.getCursor();
        if (cur.ch > 0) cm.setCursor(cur.line, cur.ch - 1);
      }
      return result;
    };

    // cc / S keep the indent; with nothing typed, <Esc> removes it again.
    var change = vimOperators.change;
    vimOperators.change = function (cm, args) {
      var result = change.apply(this, arguments);
      if (args.linewise && cm.state.vim.insertMode) {
        var cur = cm.getCursor(), text = cm.getLine(cur.line);
        cm.$autoIndent = text && /^[ \t]+$/.test(text) && cur.ch == text.length ? { line: cur.line, text: text } : null;
      }
      return result;
    };

    vimActions.joinLines = function (cm, args, vim) {
      var from, to;
      if (vim.visualMode) {
        var a = cm.getCursor("anchor"), h = cm.getCursor("head");
        from = Math.min(a.line, h.line);
        to = Math.max(a.line, h.line);
        if (to == from) to++;
      } else {
        from = cm.getCursor().line;
        to = from + Math.max(args.repeat, 2) - 1;
      }
      to = Math.min(to, cm.lastLine());
      var pos = to > from ? joinRange(cm, from, to, args.keepSpaces) : cm.getCursor();
      if (vim.visualMode) Vim.exitVisualMode(cm, false);
      cm.setCursor(pos);
    };

    // Linewise deletes through the last line (dd there, dG, :$d, :g/x/d):
    // remove the line break before them, store just the lines ("c\n", not
    // "\nc\n"), and leave no empty line behind.
    var del = vimOperators["delete"];
    vimOperators["delete"] = function (cm, args, ranges) {
      var vim = cm.state.vim;
      if (args.linewise && !vim.visualBlock && ranges.length == 1) {
        var a = ranges[0].anchor, h = ranges[0].head;
        var start = a.line <= h.line ? a : h, end = start === a ? h : a;
        var last = cm.lastLine();
        if (end.line > last && start.line > cm.firstLine()) {
          var lastEnd = new Pos(last, cm.getLine(last).length);
          var text = cm.getRange(new Pos(start.line, 0), lastEnd);
          cm.replaceRange("", new Pos(start.line - 1, cm.getLine(start.line - 1).length), lastEnd);
          Vim.getRegisterController().pushText(args.registerName, "delete", text, true, false);
          var line = cm.getLine(start.line - 1), first = line.search(/\S/);
          return new Pos(start.line - 1, first < 0 ? Math.max(line.length - 1, 0) : first);
        }
      }
      return del.apply(this, arguments);
    };
  }

  function firstNonBlank(cm, line) {
    var text = cm.getLine(line), ch = text.search(/\S/);
    return new Pos(line, ch < 0 ? Math.max(text.length - 1, 0) : ch);
  }
  function lastSearchText() {
    var reg = Vim.getRegisterController().getRegister("/");
    return reg ? reg.toString() : "";
  }

  // Leaving insert mode on a line that holds only the indent 'autoindent'
  // gave it (o<Esc>) empties the line, as in Vim.
  proto.$dropAutoIndent = function () {
    var auto = this.$autoIndent;
    this.$autoIndent = null;
    if (!auto || auto.line > this.lastLine() || this.getCursor().line != auto.line) return;
    if (this.getLine(auto.line) !== auto.text) return;
    this.replaceRange("", new Pos(auto.line, 0), new Pos(auto.line, auto.text.length));
    this.setCursor(auto.line, 0);
  };

  // ---- U, gp, gP ---------------------------------------------------------------

  Vim.defineAction("vimkitUndoLine", function (cm) { cm.$undoLine(); });
  Vim._mapCommand({ keys: "U", type: "action", action: "vimkitUndoLine", context: "normal" });

  // gp / gP put like p / P and leave the cursor just after the new text.
  Vim.defineAction("vimkitPutAfterText", function (cm, actionArgs, vim) {
    var register = Vim.getRegisterController().getRegister(actionArgs.registerName);
    var cur = cm.getCursor(), lines = cm.lineCount(), length = cm.getValue().length;
    var start = cm.indexFromPos(cur) + (actionArgs.after && cm.getLine(cur.line).length ? 1 : 0);
    vimActions.paste.call(vimActions, cm, actionArgs, vim);
    var added = cm.lineCount() - lines;
    if (register.blockwise) {
      var rows = register.toString().split("\n"), width = 0;
      rows.forEach(function (r) { width = Math.max(width, r.length); });
      cm.setCursor(new Pos(cur.line + rows.length - 1, cur.ch + (actionArgs.after ? 1 : 0) + width));
    } else if (register.linewise) {
      var line = cur.line + (actionArgs.after ? 1 : 0) + added;
      cm.setCursor(line > cm.lastLine() ? new Pos(cm.lastLine(), 0) : new Pos(line, 0));
    } else {
      cm.setCursor(cm.posFromIndex(start + cm.getValue().length - length));
    }
  });
  Vim._mapCommand({ keys: "gp", type: "action", action: "vimkitPutAfterText", isEdit: true, actionArgs: { after: true, isEdit: true }, context: "normal" });
  Vim._mapCommand({ keys: "gP", type: "action", action: "vimkitPutAfterText", isEdit: true, actionArgs: { after: false, isEdit: true }, context: "normal" });

  // ---- visual block over short lines; <C-a> / <C-x> in visual mode -------------

  // A block yanked over a line that ends before the block starts holds that
  // line as spaces as wide as the block (a line that ends just where the
  // block starts holds nothing), as in Vim.
  function withBlockPadding(cm, vim, ranges, operator, self, args) {
    var a = vim.sel.anchor, h = vim.sel.head;
    var left = Math.min(a.ch, h.ch), width = Math.abs(a.ch - h.ch) + 1;
    var toEnd = vim.lastHPos == Infinity || h.ch == Infinity;
    if (toEnd) return operator.apply(self, args);
    var getSelections = cm.getSelections;
    cm.getSelections = function () {
      var texts = getSelections.apply(this, arguments);
      return texts.map(function (t, i) {
        var line = ranges[i] && Math.min(ranges[i].anchor.line, ranges[i].head.line);
        return t == "" && line != null && cm.getLine(line).length < left ? new Array(width + 1).join(" ") : t;
      });
    };
    try { return operator.apply(self, args); }
    finally { delete cm.getSelections; }
  }

  // <C-a> / <C-x> add [count] to the first number of each selected line;
  // g<C-a> / g<C-x> add [count], 2*[count], ... down the lines.
  Vim.defineAction("vimkitVisualIncrement", function (cm, args, vim) {
    var a = vim.sel.anchor, h = vim.sel.head, top = Math.min(a.line, h.line), bottom = Math.max(a.line, h.line);
    var before = a.line < h.line || (a.line == h.line && a.ch <= h.ch);
    var first = before ? a : h, last = before ? h : a;
    var left = Math.min(a.ch, h.ch), right = vim.lastHPos == Infinity ? Infinity : Math.max(a.ch, h.ch);
    var block = vim.visualBlock, linewise = vim.visualLine;
    var step = (args.repeat || 1) * (args.increase ? 1 : -1), n = 0;
    var re = /(-?)(?:(0x)([\da-f]+)|(0b|0|)(\d+))/i;
    cm.operation(function () {
      for (var line = top; line <= bottom; line++) {
        var text = cm.getLine(line), from = 0, to = text.length;
        if (block) { from = left; to = Math.min(text.length, right + 1); }
        else if (!linewise) {
          if (line == first.line) from = first.ch;
          if (line == last.line) to = Math.min(text.length, last.ch + 1);
        }
        var m = re.exec(text.slice(from, to));
        if (!m) continue;
        n++;
        var baseStr = m[2] || m[4], digits = m[3] || m[5];
        var base = { "0b": 2, "0": 8, "": 10, "0x": 16 }[baseStr.toLowerCase()];
        if (baseStr == "0" && /[89]/.test(digits)) { base = 10; digits = "0" + digits; baseStr = ""; }
        var number = parseInt(m[1] + digits, base) + step * (args.progressive ? n : 1);
        var str = Math.abs(number).toString(base);
        var pad = baseStr ? new Array(Math.max(digits.length - str.length, 0) + 1).join("0") : "";
        str = (number < 0 ? "-" : "") + baseStr + pad + str;
        var start = from + m.index;
        cm.replaceRange(str, new Pos(line, start), new Pos(line, start + m[0].length));
      }
    });
    Vim.exitVisualMode(cm, false);
    cm.setCursor(block ? new Pos(top, left) : linewise ? new Pos(top, 0) : first);
  });
  [["<C-a>", true, false], ["<C-x>", false, false], ["g<C-a>", true, true], ["g<C-x>", false, true]].forEach(function (k) {
    Vim._mapCommand({ keys: k[0], type: "action", action: "vimkitVisualIncrement",
      actionArgs: { increase: k[1], progressive: k[2] }, context: "visual" });
  });

  // ---- quote text objects -------------------------------------------------------

  // i" / a" as in Vim: \ escapes a quote; on a quote, quotes pair up from the
  // start of the line; elsewhere the nearest quotes around the cursor count,
  // or the first pair after it. a" takes the white space after the string
  // (or, if none, before it); 2i" takes the quotes without white space.
  function quoteObject(cm, head, q, inner, count) {
    var text = cm.getLine(head.line), c = head.ch;
    var isQuote = function (i) {
      if (text.charAt(i) != q) return false;
      var n = 0;
      for (var j = i - 1; j >= 0 && text.charAt(j) == "\\"; j--) n++;
      return n % 2 == 0;
    };
    var next = function (i) { for (; i < text.length; i++) if (isQuote(i)) return i; return -1; };
    var prev = function (i) { for (; i >= 0; i--) if (isQuote(i)) return i; return -1; };
    var open, close;
    if (isQuote(c)) {
      var before = 0;
      for (var i = 0; i < c; i++) if (isQuote(i)) before++;
      if (before % 2 == 0) { open = c; close = next(c + 1); }
      else { close = c; open = prev(c - 1); }
    } else {
      open = prev(c - 1);
      close = open < 0 ? -1 : next(c + 1);
      if (open < 0 || close < 0) {
        open = next(c + 1);
        close = open < 0 ? -1 : next(open + 1);
      }
    }
    if (open < 0 || close < 0) return null;
    var start = open + 1, end = close;
    if (inner && count >= 2) { start = open; end = close + 1; }
    else if (!inner) {
      start = open;
      end = close + 1;
      var t = end;
      while (t < text.length && /[ \t]/.test(text.charAt(t))) t++;
      if (t > end) end = t;
      else while (start > 0 && /[ \t]/.test(text.charAt(start - 1))) start--;
    }
    return { start: new Pos(head.line, start), end: new Pos(head.line, end) };
  }

  // ---- search offsets (/pat/e, /pat/+1, ?pat?s-1), g_, go -----------------------

  // The offset of the last search, as Vim remembers it for n and N.
  var searchOffset = null; // { kind: "line" | "end" | "start", n }
  function takeSearchOffset(value, delimiter) {
    if (!value) return value; // "/" alone: last pattern, last offset
    for (var i = 0; i < value.length; i++) {
      if (value.charAt(i) == "\\") { i++; continue; }
      if (value.charAt(i) != delimiter) continue;
      var m = /^(?:([esb])([+-]\d*)?|([+-]?\d*))$/.exec(value.slice(i + 1));
      if (!m) break;
      var number = function (t) { return !t ? 0 : t == "+" ? 1 : t == "-" ? -1 : +t; };
      if (m[1]) searchOffset = { kind: m[1] == "e" ? "end" : "start", n: number(m[2]) };
      else searchOffset = m[3] ? { kind: "line", n: number(m[3]) } : null;
      return value.slice(0, i);
    }
    searchOffset = null;
    return value;
  }
  // With an e offset Vim searches by the end of the match: forward, the
  // first match that ends after the cursor (it may start before it);
  // backward, the last one that ends before it.
  function endOffsetMatch(cm, found, motionArgs) {
    var state = cm.state.vim && cm.state.vim.searchState_, query = state && state.getQuery();
    if (!query || (motionArgs.repeat || 1) > 1) return found;
    var cur = cm.indexFromPos(cm.getCursor()), forward = !!motionArgs.forward != !!state.isReversed();
    var endOf = function (pos) {
      var c = cm.getSearchCursor(query, pos);
      return c.findNext() ? cm.indexFromPos(c.to()) - 1 : -1;
    };
    if (forward) {
      var c = cm.getSearchCursor(query, new Pos(cm.getCursor().line, 0));
      while (c.findNext()) {
        var from = cm.indexFromPos(c.from()), end = cm.indexFromPos(c.to()) - 1;
        if (from > cur) break;
        if (end > cur) return c.from();
      }
      return found;
    }
    if (endOf(found) < cur) return found;
    var back = cm.getSearchCursor(query, found);
    return back.findPrevious() ? back.from() : found;
  }
  function applySearchOffset(cm, pos, motionArgs) {
    var off = searchOffset;
    if (!off || !pos) return pos;
    if (off.kind == "line") {
      var line = Math.max(cm.firstLine(), Math.min(cm.lastLine(), pos.line + off.n));
      motionArgs.linewise = true;
      return new Pos(line, 0);
    }
    var at = cm.indexFromPos(pos);
    if (off.kind == "end") {
      var state = cm.state.vim && cm.state.vim.searchState_, query = state && state.getQuery();
      if (query) {
        var cursor = cm.getSearchCursor(query, pos);
        if (cursor.findNext()) at = cm.indexFromPos(cursor.to()) - 1;
      }
      motionArgs.inclusive = true;
    }
    at = Math.max(0, Math.min(cm.doc.getLength(), at + off.n));
    return cm.posFromIndex(at);
  }

  // g_: the last non-blank character, [count]-1 lines down.
  Vim.defineMotion("vimkitLastNonBlank", function (cm, head, motionArgs) {
    var line = Math.min(head.line + (motionArgs.repeat || 1) - 1, cm.lastLine());
    var text = cm.getLine(line), ch = text.search(/\s*$/) - 1;
    return new Pos(line, Math.max(ch, 0));
  });
  Vim.mapCommand("g_", "motion", "vimkitLastNonBlank", { inclusive: true }, {});
  // [count]go: byte [count] of the text (UTF-8, as Vim counts).
  Vim.defineMotion("vimkitGoByte", function (cm, head, motionArgs) {
    var target = (motionArgs.repeat || 1) - 1, text = cm.getValue(), bytes = 0, i = 0;
    while (i < text.length) {
      var code = text.codePointAt(i), size = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
      if (bytes + size > target) break;
      bytes += size;
      i += code > 0xffff ? 2 : 1;
    }
    var pos = cm.posFromIndex(Math.min(i, text.length));
    var len = cm.getLine(pos.line).length;
    return new Pos(pos.line, Math.min(pos.ch, Math.max(len - 1, 0)));
  });
  Vim.mapCommand("go", "motion", "vimkitGoByte", { toJumplist: true }, {});

  // ---- :&, &, g& --------------------------------------------------------------

  var lastSubstitute = null; // { d, pattern, replacement, flags } in Vim syntax
  function repeatSubstitute(cm, params, flags, count, searchPattern) {
    var last = lastSubstitute;
    if (!last) { showMessage(cm, "E35: No previous regular expression", true); return; }
    var d = last.d, copy = {};
    for (var k in params) copy[k] = params[k];
    copy.argString = d + (searchPattern ? "" : last.pattern) + d + last.replacement + d + flags + (count ? " " + count : "");
    copy.commandName = "substitute";
    exCommands.substitute(cm, copy);
  }
  Vim.defineAction("vimkitRepeatSubstitute", function (cm, args) {
    if (!lastSubstitute) { showMessage(cm, "E33: No previous substitute regular expression", true); return; }
    var line = cm.getCursor().line;
    if (args.all) {
      repeatSubstitute(cm, { line: cm.firstLine(), lineEnd: cm.lastLine(), selectionLine: cm.firstLine(), selectionLineEnd: cm.lastLine() },
        lastSubstitute.flags, "", true);
    } else {
      repeatSubstitute(cm, { selectionLine: line }, "", "", false);
    }
  });
  Vim._mapCommand({ keys: "&", type: "action", action: "vimkitRepeatSubstitute", actionArgs: { all: false }, context: "normal" });
  Vim._mapCommand({ keys: "g&", type: "action", action: "vimkitRepeatSubstitute", actionArgs: { all: true }, context: "normal" });

  // ---- ex commands vim.js lacks or gets wrong: :m, :t, :co, :>, :<, :j --------

  // An ex address: N, ., $ or 'x, with +N / -N offsets; -1 is address 0.
  function parseAddress(cm, text) {
    var m = /^\s*(\d+|\.|\$|'.)?((?:\s*[+-]\d*)*)\s*$/.exec(text || "");
    if (!m || (!m[1] && !m[2])) return null;
    var line;
    if (!m[1] || m[1] == ".") line = cm.getCursor().line;
    else if (m[1] == "$") line = cm.lastLine();
    else if (m[1].charAt(0) == "'") {
      var mark = cm.state.vim.marks[m[1].charAt(1)], p = mark && mark.find();
      if (!p) return null;
      line = p.line;
    } else line = +m[1] - 1;
    (m[2].match(/[+-]\d*/g) || []).forEach(function (o) {
      line += (o.charAt(0) == "-" ? -1 : 1) * (o.length > 1 ? +o.slice(1) : 1);
    });
    return line;
  }
  function exRange(params) {
    var line = params.selectionLine, end = params.selectionLineEnd;
    if (end == null || isNaN(end)) end = line;
    return line <= end ? [line, end] : [end, line];
  }
  function linesOf(cm, from, to) {
    var out = [];
    for (var i = from; i <= to; i++) out.push(cm.getLine(i));
    return out;
  }
  // Inserts whole lines after line `at` (-1: before the first line).
  function insertLines(cm, at, lines) {
    if (at < 0) cm.replaceRange(lines.join("\n") + "\n", new Pos(0, 0));
    else cm.replaceRange("\n" + lines.join("\n"), new Pos(at, cm.getLine(at).length));
  }
  function deleteLines(cm, from, to) {
    var last = cm.lastLine();
    if (to < last) cm.replaceRange("", new Pos(from, 0), new Pos(to + 1, 0));
    else if (from > 0) cm.replaceRange("", new Pos(from - 1, cm.getLine(from - 1).length), new Pos(to, cm.getLine(to).length));
    else cm.replaceRange("", new Pos(0, 0), new Pos(to, cm.getLine(to).length));
  }

  // :[range]m {address}
  Vim.defineEx("movelines", "m", function (cm, params) {
    var r = exRange(params), dest = parseAddress(cm, params.argString);
    if (dest == null || dest < -1 || dest > cm.lastLine()) { showMessage(cm, "E14: Invalid address", true); return; }
    if (dest >= r[0] && dest < r[1]) { showMessage(cm, "E134: Cannot move a range of lines into itself", true); return; }
    var count = r[1] - r[0] + 1, at = dest;
    if (dest != r[1] && dest != r[0] - 1) {
      var lines = linesOf(cm, r[0], r[1]);
      deleteLines(cm, r[0], r[1]);
      if (dest > r[1]) at = dest - count;
      insertLines(cm, at, lines);
    } else {
      at = r[0] - 1;
    }
    cm.setCursor(firstNonBlank(cm, at + count));
  });

  // :[range]t {address}, :[range]co[py] {address}
  function copyLines(cm, params) {
    var r = exRange(params), dest = parseAddress(cm, params.argString);
    if (dest == null || dest < -1 || dest > cm.lastLine()) { showMessage(cm, "E14: Invalid address", true); return; }
    insertLines(cm, dest, linesOf(cm, r[0], r[1]));
    cm.setCursor(firstNonBlank(cm, dest + r[1] - r[0] + 1));
  }
  Vim.defineEx("copy", "co", copyLines);
  Vim.defineEx("t", "t", copyLines);

  // :[range]> [count], :[range]>> ... and the same with <.
  function shiftLines(right) {
    return function (cm, params) {
      var r = exRange(params), m = /^([<>]*)\s*(\d*)\s*$/.exec(params.argString || "");
      if (!m) { showMessage(cm, "E488: Trailing characters: " + params.argString, true); return; }
      var times = 1 + m[1].length;
      if (m[2]) { r[0] = r[1]; r[1] = Math.min(r[0] + +m[2] - 1, cm.lastLine()); }
      for (var i = r[0]; i <= r[1]; i++) {
        if (!cm.getLine(i).length) continue; // Vim leaves empty lines alone
        for (var k = 0; k < times; k++) cm.indentLine(i, right);
      }
      cm.setCursor(firstNonBlank(cm, r[1]));
    };
  }
  Vim.defineEx(">", ">", shiftLines(true));
  Vim.defineEx("<", "<", shiftLines(false));

  // J and gJ as in Vim: no space before ")", after a line that ends in white
  // space, or when the text so far is empty; gJ keeps all white space.
  function joinRange(cm, from, to, keepSpaces) {
    var finalCh = 0;
    for (var i = from; i < to; i++) {
      var cur = cm.getLine(from), next = cm.getLine(from + 1);
      var start = 0, text = "";
      if (!keepSpaces) {
        start = next.search(/\S/);
        if (start < 0) start = next.length;
        var rest = next.slice(start), end = cur.charAt(cur.length - 1);
        if (rest && rest.charAt(0) != ")" && cur.length && end != " " && end != "\t") text = " ";
      }
      finalCh = cur.length;
      cm.replaceRange(text, new Pos(from, cur.length), new Pos(from + 1, start));
    }
    var len = cm.getLine(from).length;
    return new Pos(from, Math.max(Math.min(finalCh, len - 1), 0));
  }

  // :[range]j[oin][!] [count]
  Vim.defineEx("join", "j", function (cm, params) {
    var line = params.selectionLine, end = params.selectionLineEnd;
    var hasRange = end != null && !isNaN(end);
    var arg = params.argString || "", bang = /^!/.test(arg);
    var m = /^!?\s*(\d*)\s*$/.exec(arg);
    if (!m) { showMessage(cm, "E488: Trailing characters: " + arg, true); return; }
    var r = hasRange ? exRange(params) : [line, line];
    if (m[1]) r = [r[1], r[1] + +m[1] - 1];
    else if (!hasRange) r[1]++;
    r[1] = Math.min(r[1], cm.lastLine());
    if (r[1] > r[0]) joinRange(cm, r[0], r[1], bang);
    cm.setCursor(firstNonBlank(cm, r[0]));
  });

  // ---- insert mode: <C-w>, <C-u>, <C-h>, <C-a>, <C-y>, <C-e>, replace <BS> -----

  // Where this insert started; a cursor key moves it to where it lands.
  proto.$resolveInsertStart = function () {
    if (!this.$insertStartPending) return;
    this.$insertStartPending = false;
    var vim = this.state.vim;
    if (vim && vim.insertMode) this.$insertStart = this.getCursor();
  };

  function isKeywordChar(ch) { return /[\w\u00c0-\uffff]/.test(ch); }

  // <C-w> and <C-u> as in Vim with 'backspace' indent,eol,start: they stop
  // once at the start of the insert, join lines at column 0, leave the
  // registers alone, and <C-u> keeps the indent ('autoindent').
  proto.$insertDelete = function (what) {
    var cur = this.getCursor(), start = this.$insertStart, text = this.getLine(cur.line), from;
    var typed = start && start.line == cur.line && start.ch < cur.ch;
    if (cur.ch == 0) {
      if (cur.line == 0) return;
      from = new Pos(cur.line - 1, this.getLine(cur.line - 1).length);
    } else if (what == "line") {
      var indent = text.search(/\S/);
      from = new Pos(cur.line, typed ? start.ch : indent >= 0 && indent < cur.ch ? indent : 0);
    } else {
      var ch = cur.ch;
      while (ch > 0 && /\s/.test(text.charAt(ch - 1))) ch--;
      if (ch > 0) {
        var kw = isKeywordChar(text.charAt(ch - 1));
        while (ch > 0 && !/\s/.test(text.charAt(ch - 1)) && isKeywordChar(text.charAt(ch - 1)) == kw) ch--;
      }
      if (typed && ch < start.ch) ch = start.ch;
      from = new Pos(cur.line, ch);
    }
    this.replaceRange("", from, cur, "+delete");
    this.setCursor(from);
    if (start && (from.line < start.line || (from.line == start.line && from.ch < start.ch))) this.$insertStart = from;
  };

  // <BS> in replace mode puts back what was overwritten.
  proto.$replaceBackspace = function () {
    var stack = this.$replaced || [], top = stack[stack.length - 1];
    var head = this.indexFromPos(this.getCursor());
    if (top && top.at + top.length == head) {
      stack.pop();
      this.replaceRange(top.original, this.posFromIndex(top.at), this.posFromIndex(head), "+delete");
      this.setCursor(this.posFromIndex(top.at));
    } else {
      CodeMirror.commands.cursorCharLeft(this);
    }
  };

  Vim.defineAction("vimkitInsertDelete", function (cm, args) { cm.$insertDelete(args.what); });
  Vim._mapCommand({ keys: "<C-w>", type: "action", action: "vimkitInsertDelete", actionArgs: { what: "word" }, context: "insert" });
  Vim._mapCommand({ keys: "<C-u>", type: "action", action: "vimkitInsertDelete", actionArgs: { what: "line" }, context: "insert" });
  Vim.defineAction("vimkitInsertBackspace", function (cm) {
    if (cm.state.overwrite) cm.$replaceBackspace();
    else cm.$deleteChar(-1);
  });
  Vim._mapCommand({ keys: "<C-h>", type: "action", action: "vimkitInsertBackspace", context: "insert" });
  // <C-a>: the text of the last insert (the "." register).
  Vim.defineAction("vimkitInsertLast", function (cm) {
    var text = Vim.getRegisterController().getRegister(".").toString();
    if (text) cm.replaceSelection(text);
  });
  Vim._mapCommand({ keys: "<C-a>", type: "action", action: "vimkitInsertLast", context: "insert" });
  // <C-y> / <C-e>: the character above / below the cursor, by screen column.
  Vim.defineAction("vimkitInsertCopyLine", function (cm, args) {
    var cur = cm.getCursor(), line = cur.line + args.dir;
    if (line < cm.firstLine() || line > cm.lastLine()) return;
    var tab = cm.getOption("tabSize"), col = countColumn(cm.getLine(cur.line).slice(0, cur.ch), tab);
    var text = cm.getLine(line), at = 0, c = 0;
    while (at < text.length && c < col) { c = countColumn(text.slice(0, at + 1), tab); at++; }
    if (c != col || at >= text.length) return;
    cm.replaceSelection(text.charAt(at));
  });
  Vim._mapCommand({ keys: "<C-y>", type: "action", action: "vimkitInsertCopyLine", actionArgs: { dir: -1 }, context: "insert" });
  Vim._mapCommand({ keys: "<C-e>", type: "action", action: "vimkitInsertCopyLine", actionArgs: { dir: 1 }, context: "insert" });

  // In normal mode the cursor stays on a character: after a command it is
  // never past the end of the line (~ at the end, :normal A;, ...).
  proto.$clipNormalCursor = function () {
    var vim = this.state.vim;
    if (!vim || vim.insertMode || vim.visualMode || vim.insertModeReturn || this.dialog) return;
    var input = vim.inputState;
    if (input.operator || input.keyBuffer.length || this.sel.ranges.length != 1 || this.somethingSelected()) return;
    var cur = this.getCursor(), line = this.getLine(cur.line), len = line.length;
    if (!len || cur.ch < len) return;
    var ch = len - 1;
    if (ch > 0 && /[\udc00-\udfff]/.test(line.charAt(ch)) && /[\ud800-\udbff]/.test(line.charAt(ch - 1))) ch--;
    var hpos = vim.lastHPos;
    this.setCursor(cur.line, ch);
    vim.lastHPos = hpos == cur.ch ? ch : hpos;
  };

  // vim.js's ex command table, for wrapping its commands.
  var exCommands = null;
  Vim.defineEx("vimkitexcommands", "vimkitexcommands", function () { exCommands = this; });
  function wrapExCommands(cm) {
    captureTables(cm);
    if (exCommands) return;
    var history = Vim.getRegisterController().getRegister(":"), previous = history.toString();
    Vim.handleEx(cm, "vimkitexcommands");
    history.setText(previous);
    if (!exCommands) return;

    // :[range]d [x] [count]: the register and count, and the cursor on the
    // line after the deleted ones, at its first non-blank.
    exCommands["delete"] = function (cm, params) {
      var line = params.selectionLine;
      var end = isNaN(params.selectionLineEnd) ? line : params.selectionLineEnd;
      var arg = (params.argString || "").trim();
      // Anything else after :d is ignored, as vim.js does.
      var m = /^([^\d\s])?\s*(\d+)?$/.exec(arg) || [];
      if (m[1] && !Vim.getRegisterController().isValidRegister(m[1])) m = [];
      if (m[2]) {
        line = end;
        end = Math.min(line + +m[2] - 1, cm.lastLine());
      }
      vimOperators["delete"](cm, { linewise: true, registerName: m[1] || "" },
        [{ anchor: new Pos(line, 0), head: new Pos(end + 1, 0) }]);
      cm.setCursor(firstNonBlank(cm, Math.min(line, cm.lastLine())));
    };

    // :s leaves the cursor on the last line it changed, at the first
    // non-blank. No match is E486, except inside :g, which goes on.
    var substitute = exCommands.substitute;
    exCommands.substitute = function (cm, params) {
      var note = cm.notification, callback = params.callback, dialog = cm.dialog;
      cm.$lastReplaceEnd = null;
      // /pat/rep/[flags][count]: Vim's replacement syntax, and the count
      // (vim.js reads it only after a space).
      var parts = /^(\W)((?:\\.|(?!\1).)*)(?:\1((?:\\.|(?!\1).)*)(?:\1([&cegiInp#lr]*)\s*(\d*)\s*)?)?$/.exec(params.argString || "");
      if (parts && parts[3] != null) {
        lastSubstitute = { d: parts[1], pattern: parts[2] || lastSearchText(), replacement: parts[3], flags: parts[4] || "" };
      }
      if (parts && parts[3] != null && !Vim.getOption("pcre")) {
        var d = parts[1];
        params.argString = d + parts[2] + d + vimReplacement(parts[3])
          + (parts[4] != null ? d + parts[4] + (parts[5] ? " " + parts[5] : "") : "");
      }
      var result = substitute.apply(this, arguments);
      var now = cm.notification, fresh = now && now !== note ? now.text : "";
      var m = /^(\W)((?:\\.|(?!\1).)*)/.exec(params.argString || "");
      var pattern = m && m[2] ? m[2] : lastSearchText();
      if (/^No matches for /.test(fresh)) {
        if (callback) {
          if (cm.notification === now) cm.$closeNotification();
          callback();
        } else {
          showMessage(cm, "E486: Pattern not found: " + pattern, true);
        }
        return result;
      }
      // vim.js reports the count of every :s; Vim only with the n flag.
      if (/^Found \d+ matches/.test(fresh) && !/n[^\/]*$/.test(params.argString || "")) cm.$closeNotification();
      // Not while asking y/n/a/q (the c flag). A match that starts at a line
      // break (:%s/\n//) leaves the cursor on it, as in Vim.
      if ((!cm.dialog || cm.dialog === dialog) && !/^\\n/.test(pattern)) {
        // The last changed line is where the last replacement ends (it may
        // have broken the line).
        var end = cm.$lastReplaceEnd;
        cm.setCursor(firstNonBlank(cm, end != null ? cm.posFromIndex(end).line : cm.getCursor().line));
      }
      return result;
    };

    // :[range]&[&][flags] [count] repeats the last :s (&& keeps its flags);
    // & in normal mode is :s, g& is :%s//~/& (with the last search pattern).
    Vim.defineEx("&", "&", function (cm, params) {
      var m = /^(&?)([cegiInp#lr]*)\s*(\d*)\s*$/.exec((params.argString || "").trim());
      if (!m) { showMessage(cm, "E488: Trailing characters: " + params.argString, true); return; }
      repeatSubstitute(cm, params, (m[1] && lastSubstitute ? lastSubstitute.flags : "") + m[2], m[3], false);
    });

    // :set nu rnu sets each option.
    var set = exCommands.set;
    exCommands.set = function (cm, params) {
      var args = params.args;
      if (!args || args.length < 2) return set.call(this, cm, params);
      for (var i = 0; i < args.length; i++) {
        var one = {};
        for (var k in params) one[k] = params[k];
        one.args = [args[i]];
        one.argString = args[i];
        set.call(this, cm, one);
      }
    };
  }

  proto.getVimOption = function (name) {
    var v = Vim.getOption(name, this);
    return v instanceof Error || v === undefined ? null : v;
  };
  proto.setVimOption = function (name, value) {
    var r = Vim.setOption(name, value, this, { scope: "local" });
    return !(r instanceof Error);
  };

  // <C-r>{register}, <C-r><C-w> (word), <C-r><C-a> (WORD), <C-r><C-l> (line)
  // in the `:` and `/` prompts. True when the key was used here.
  proto.$promptRegisterKey = function (e) {
    var d = this.dialog, plain = !e.ctrlKey && !e.altKey && !e.metaKey;
    if (!d.$ctrlR) {
      if (e.ctrlKey && !e.altKey && !e.metaKey && e.key == "r") { d.$ctrlR = true; return true; }
      return false;
    }
    d.$ctrlR = false;
    var text = null;
    if (e.ctrlKey && !e.altKey && !e.metaKey && (e.key == "w" || e.key == "a")) {
      text = expandArg(this, e.key == "w" ? "<cword>" : "<cWORD>");
    } else if (e.ctrlKey && e.key == "l") {
      text = this.getLine(this.getCursor().line);
    } else if (plain && e.key.length == 1 && e.key != "=") {
      var rc = ensureRegisters();
      if (rc.isValidRegister(e.key)) text = rc.getRegister(e.key).toString().replace(/\n$/, "");
    }
    if (text) {
      var input = d.input, v = input.value, at = Math.max(0, Math.min(input.selectionEnd, v.length));
      input.value = v.slice(0, at) + text + v.slice(at);
      input.selectionStart = input.selectionEnd = at + text.length;
      if (d.options.onInput) d.options.onInput(makeEvent(e, input), input.value, d.close);
    }
    return true;
  };

  global.VimKit = {
    Vim: Vim,
    CodeMirror: CodeMirror,
    createEditor: function (host, text, options) {
      var cm = new CodeMirror(host, text, options);
      cm.on("vim-mode-change", function (e) {
        if (e.mode != "insert" && e.mode != "replace") cm.$dropAutoIndent();
        // A block insert (<C-v>I, <C-v>A) ends at the top left of the block.
        if (e.mode == "normal" && cm.$blockInsertStart) {
          var at = cm.$blockInsertStart;
          cm.$blockInsertStart = null;
          cm.setCursor(at);
        } else if (e.mode != "insert") cm.$blockInsertStart = null;
        // The insert starts where the first key after entering it finds the
        // cursor (A, o and the like move it after the mode changes).
        cm.$insertStart = null;
        cm.$insertStartPending = e.mode == "insert" || e.mode == "replace";
        cm.$replaced = [];
        cm.$mode = e.mode || "normal";
        cm.$subMode = e.subMode || "";
        if (cm.state.vim) cm.state.vim.status = "";
        cm.$emitState();
      });
      cm.on("vim-command-done", function () {
        if (cm.state.vim) cm.state.vim.status = "";
        cm.$emitState();
      });
      Vim.enterVimMode(cm);
      wrapExCommands(cm);
      cm.curOp = null;
      cm.$emitState();
      return cm;
    },
    defineEx: defineHostEx,
    // Registers for the host: { text, kind } or null; kind is "c", "l" or "b".
    getRegister: function (name) {
      var rc = ensureRegisters();
      if (!rc.isValidRegister(name)) return null;
      var reg = name == '"' ? rc.unnamedRegister : rc.getRegister(name);
      var text = reg ? reg.toString() : "";
      if (!text) return null;
      return { text: text, kind: reg.blockwise ? "b" : reg.linewise ? "l" : "c" };
    },
    setRegister: function (name, text, kind) {
      var rc = ensureRegisters();
      if (!rc.isValidRegister(name) || name == "_" || ".:%#=".indexOf(name) >= 0) return false;
      var reg = name == '"' ? rc.unnamedRegister : rc.getRegister(name.toLowerCase());
      if (text == null) reg.setText("");
      else reg.setText(String(text), kind == "l", kind == "b");
      return true;
    },
    registerNames: function () {
      var rc = ensureRegisters(), out = [];
      for (var i = 0; i < registerOrder.length; i++) {
        var n = registerOrder.charAt(i), reg = n == '"' ? rc.unnamedRegister : rc.registers[n];
        if (reg && reg.toString()) out.push(n);
      }
      return out.join("");
    },
    exec: function (command) {
      // Global commands (:map, :set, ...) need an editor; use a throwaway one.
      var silent = {
        replace: function () {}, select: function () {}, state: function () {}, event: function () {},
        ex: function () {}, coords: function () { return []; }, offsetAt: function () { return -1; },
        scrollInfo: function () { return []; }, scrollTo: function () {}, scrollIntoView: function () {},
        moveVertically: function () { return -1; }, lineBoundary: function () { return -1; },
        lineHeight: function () { return 0; }, edits: function () {}, tokenType: function () { return ""; }
      };
      var cm = this.createEditor(silent, "");
      try { Vim.handleEx(cm, command); } finally { cm.destroy(); }
    }
  };
})(this);

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
      readText: function () { return Promise.resolve(runtime.clipboardRead() || ""); }
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
        var match = this.string.slice(this.pos).match(pattern);
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
    }
    return this.starts;
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
    var starts = this.index();
    return starts[line] + clamp(ch || 0, 0, this.lines[line].length);
  };
  Doc.prototype.posFromIndex = function (offset) {
    var starts = this.index();
    offset = clamp(offset, 0, this.length);
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
    }
    return new Pos(lo, offset - starts[lo]);
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
        var delta = text.length - (to - from);
        for (var i = a.line + 1; i < this.starts.length; i++) this.starts[i] += delta;
        this.length += delta;
      }
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
      lineComment: null, viewportLines: 30
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
  CodeMirror.findEnclosingTag = function () { return undefined; };
  CodeMirror.keyName = undefined;

  CodeMirror.commands = {
    undo: function (cm) { cm.undo(); },
    redo: function (cm) { cm.redo(); },
    cursorCharLeft: function (cm) { cm.moveH(-1, "char"); },
    newlineAndIndent: function (cm) {
      cm.$replaceRanges(function (from, to) {
        var line = cm.doc.posFromIndex(from).line;
        var indent = /^[ \t]*/.exec(cm.getLine(line))[0];
        return "\n" + indent.slice(0, cm.doc.posFromIndex(from).ch);
      }, "end");
    },
    indentAuto: function () {},
    toggleLineComment: function (cm) { cm.toggleLineComment(); },
    newlineAndIndentContinueComment: undefined,
    save: function (cm) { cm.host.event("save", ""); }
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
    this.$setSel([{ anchor: offset, head: offset }], 0);
    if (this.curOp && !this.curOp.isVimOp) this.onBeforeEndOperation();
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

    var curOp = this.curOp = this.curOp || {};
    if (curOp.$changeStart == null || curOp.$changeStart > from) curOp.$changeStart = from;
    var change = { text: text.split("\n"), origin: origin };
    if (!curOp.lastChange) curOp.lastChange = curOp.change = change;
    else curOp.lastChange.next = curOp.lastChange = change;
    if (!curOp.changeHandlers)
      curOp.changeHandlers = this._handlers["change"] && this._handlers["change"].slice();

    if (!fromHost) {
      this.$selDirty = true;
      this.host.replace(from, to, text);
    }
    if (this.searchQuery) this.$searchDirty = true;
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
    this.doc.setText(text);
    this.history.clear();
    this.marks = Object.create(null);
    this.$setSel([{ anchor: 0, head: 0 }], 0, true);
    this.curOp = null;
  };

  // ---- undo ------------------------------------------------------------------

  proto.$runHistory = function (from, to, invert) {
    var history = this.history;
    history.close();
    var group = from.pop();
    if (!group) return;
    history.suppressed++;
    var start = Infinity;
    try {
      var changes = group.changes;
      if (invert) {
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
  proto.undo = function () { this.$runHistory(this.history.done, this.history.undone, true); };
  proto.redo = function () { this.$runHistory(this.history.undone, this.history.done, false); };

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
    var op = this.curOp, scroll = false;
    this.$ending = true;
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
    this.$flush();
    if (scroll) this.scrollIntoView();
  };
  proto.$flush = function () {
    if (this.$selDirty) {
      this.$selDirty = false;
      var flat = [];
      this.sel.ranges.forEach(function (r) { flat.push(r.anchor, r.head); });
      this.host.select(flat, this.sel.primary);
    }
    if (this.$searchDirty) {
      this.$searchDirty = false;
      this.host.event("highlight", this.searchQuery ? "changed" : "");
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

  function globalRegExp(query) {
    var flags = query.flags.replace(/[gy]/g, "");
    if (flags.indexOf("m") < 0) flags += "m";
    return new RegExp(query.source, flags + "g");
  }

  proto.getSearchCursor = function (query, pos) {
    var cm = this, last = null, lastResult = null, afterEmptyMatch = false;
    if (pos.ch == undefined) pos.ch = Number.MAX_VALUE;
    var firstOffset = cm.indexFromPos(pos);
    var re = globalRegExp(query);

    function nextMatch(from) {
      var text = cm.doc.toString();
      if (from > text.length) return null;
      re.lastIndex = from;
      var m = re.exec(text);
      return m ? { from: m.index, to: m.index + m[0].length, match: m } : null;
    }
    function prevMatch(endAt) {
      var text = cm.doc.toString(), best = null, m;
      re.lastIndex = 0;
      while ((m = re.exec(text))) {
        if (m.index >= endAt) break;
        best = { from: m.index, to: m.index + m[0].length, match: m };
        if (m[0].length === 0) re.lastIndex++;
      }
      return best;
    }
    return {
      findNext: function () { return this.find(false); },
      findPrevious: function () { return this.find(true); },
      find: function (back) {
        if (back) {
          var endAt = last ? (afterEmptyMatch ? last.to - 1 : last.from) : firstOffset;
          last = endAt < 0 ? null : prevMatch(endAt);
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
        cm.$applyChange(last.from, last.to, text, false);
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
    var re = globalRegExp(this.searchQuery), text = this.doc.toString(), out = [], m;
    re.lastIndex = Math.max(0, from || 0);
    var end = to == null || to < 0 ? text.length : to;
    limit = limit || 10000;
    while ((m = re.exec(text)) && m.index < end && out.length < limit * 2) {
      if (m[0].length === 0) { re.lastIndex++; continue; }
      out.push(m.index, m.index + m[0].length);
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
        if (re.test(ch)) {
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
    var found = this.scanForBracket(new Pos(pos.line, pos.ch + (dir > 0 ? 1 : 0)), dir, undefined, { bracketRegex: re });
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
    if (more && !/\S/.test(text)) return;
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
  proto.indentMore = function () {
    var cm = this;
    this.operation(function () { cm.$selectedLines().forEach(function (l) { cm.indentLine(l, true); }); });
  };
  proto.indentLess = function () {
    var cm = this;
    this.operation(function () { cm.$selectedLines().forEach(function (l) { cm.indentLine(l, false); }); });
  };
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
      var target = this.host.lineBoundary(head, forward);
      if (target == null || target < 0) {
        var pos = this.posFromIndex(head);
        target = this.indexFromPos(new Pos(pos.line, forward ? Number.MAX_VALUE : 0));
      }
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
  proto.getTokenTypeAt = function () { return ""; };
  proto.getMode = function () { return { name: this.getOption("mode") }; };
  proto.foldCode = function () {};

  // ---- view geometry (delegated to the host, with headless fallbacks) -------------

  proto.defaultTextHeight = function () {
    var h = this.host.lineHeight();
    return h > 0 ? h : HEADLESS_LINE_HEIGHT;
  };
  proto.charCoords = function (pos) {
    var r = this.host.coords(this.indexFromPos(pos));
    if (r && r.length >= 3) return { left: r[0], top: r[1], bottom: r[2] };
    var p = this.clipPos(pos);
    return { left: p.ch * HEADLESS_CHAR_WIDTH, top: p.line * HEADLESS_LINE_HEIGHT, bottom: (p.line + 1) * HEADLESS_LINE_HEIGHT };
  };
  proto.coordsChar = function (coords) {
    var offset = this.host.offsetAt(coords.left, coords.top);
    if (offset != null && offset >= 0) return this.posFromIndex(offset);
    var line = clamp(Math.floor(coords.top / HEADLESS_LINE_HEIGHT), 0, this.lastLine());
    return this.clipPos(new Pos(line, Math.round(coords.left / HEADLESS_CHAR_WIDTH)));
  };
  proto.getScrollInfo = function () {
    var r = this.host.scrollInfo();
    if (r && r.length >= 6) {
      return { left: r[0], top: r[1], width: r[2], height: r[3], clientWidth: r[4], clientHeight: r[5] };
    }
    var lines = this.getOption("viewportLines");
    return {
      left: this.headlessScroll.left, top: this.headlessScroll.top,
      width: 800, height: this.lineCount() * HEADLESS_LINE_HEIGHT,
      clientWidth: 800, clientHeight: lines * HEADLESS_LINE_HEIGHT
    };
  };
  proto.scrollTo = function (x, y) {
    if (x != null) this.headlessScroll.left = x;
    if (y != null) this.headlessScroll.top = y;
    this.host.scrollTo(x == null ? NaN : x, y == null ? NaN : y);
  };
  proto.scrollIntoView = function (pos, margin) {
    var offset = pos ? this.indexFromPos(pos) : this.$primary().head;
    if (!pos) {
      // Headless: keep the cursor line inside the simulated viewport.
      var line = this.posFromIndex(offset).line, lines = this.getOption("viewportLines");
      var top = this.headlessScroll.top / HEADLESS_LINE_HEIGHT;
      if (line < top) this.headlessScroll.top = line * HEADLESS_LINE_HEIGHT;
      else if (line >= top + lines) this.headlessScroll.top = (line - lines + 1) * HEADLESS_LINE_HEIGHT;
    }
    this.host.scrollIntoView(offset, margin || 0);
  };
  proto.findPosV = function (start, amount, unit, goalColumn) {
    var count = Math.round(Math.abs(amount)), forward = amount > 0;
    var startOffset = this.indexFromPos(start);
    var offset = startOffset, viaHost = true;
    var goal = goalColumn == null ? -1 : goalColumn;
    for (var i = 0; i < count; i++) {
      var next = this.host.moveVertically(offset, forward, unit == "page", goal);
      if (next == null || next < 0) { viaHost = false; break; }
      offset = next;
    }
    var pos;
    if (viaHost) {
      pos = this.posFromIndex(offset);
    } else {
      var lines = unit == "page" ? Math.max(1, this.getOption("viewportLines") - 2) * count : count;
      var line = clamp(start.line + (forward ? lines : -lines), 0, this.lastLine());
      var ch = goalColumn == null ? start.ch : Math.round(goalColumn / HEADLESS_CHAR_WIDTH);
      pos = this.clipPos(new Pos(line, ch));
      offset = this.indexFromPos(pos);
    }
    if ((amount < 0 && offset == 0 && goalColumn != 0 && start.line == 0 && start.ch != 0) ||
        (amount > 0 && offset == this.doc.getLength() && pos.ch != goalColumn && start.line == pos.line)) {
      pos.hitSide = true;
    }
    return pos;
  };

  // ---- focus & DOM stand-ins ---------------------------------------------------------

  proto.focus = function () { this.host.event("focus", ""); };
  proto.blur = function () {};
  proto.getInputField = function () { return this.inputField; };
  proto.getWrapperElement = function () { return this.wrapper; };
  proto.setSize = function () {};
  proto.refresh = function () {};
  proto.save = function () { this.host.event("save", ""); };

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
  function isErrorTemplate(node) {
    for (var n = node; n && n.nodeType === 1; n = n.childNodes[0]) if (n.style && n.style.color === "red") return true;
    return false;
  }

  proto.openDialog = function (template, callback, options) {
    options = options || {};
    var cm = this, closed = false;
    var input = findInput(template);
    var dialog = { template: template, callback: callback, options: options, input: input, close: close };
    if (input) {
      this.$closeNotification();
      input.value = options.value || "";
      input.selectionStart = input.selectionEnd = input.value.length;
      this.dialog = dialog;
    } else {
      this.banner = dialog; // e.g. "recording @q": shown, but keys keep going to vim
    }
    function close(newVal) {
      if (typeof newVal == "string") {
        if (input) { input.value = newVal; input.selectionStart = input.selectionEnd = newVal.length; }
        cm.$emitState();
        return;
      }
      if (closed) return;
      closed = true;
      if (cm.dialog === dialog) cm.dialog = null;
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
    function close() {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      if (cm.notification === note) cm.notification = null;
      cm.$emitState();
    }
    this.$closeNotification(close);
    var note = { text: template.textContent, isError: isErrorTemplate(template) };
    this.notification = note;
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
      if (d.callback) d.callback(input.value);
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
    if (this.dialog && this.dialog.input) {
      this.$dialogKey(e);
      this.$emitState();
      return true;
    }
    var vim = this.state.vim;
    if (!vim) return false;
    var key = Vim.vimKeyFromEvent(e, vim);
    if (!key) return false;
    if (key == "<Esc>" && !vim.insertMode && !vim.visualMode && this.searchQuery) {
      var searchState = vim.searchState_;
      if (searchState) {
        this.removeOverlay(searchState.getOverlay());
        searchState.setOverlay(null);
      }
    }
    vim.status = (vim.status || "") + key;
    var result = Vim.multiSelectHandleKey(this, key, "user");
    vim = Vim.maybeInitVimState_(this);
    if (!result && vim.insertMode && this.state.overwrite) {
      if (e.key && e.key.length == 1 && !e.ctrlKey && !e.metaKey) {
        result = true;
        this.overWriteSelection(e.key);
      } else if (e.key == "Backspace") {
        result = true;
        CodeMirror.commands.cursorCharLeft(this);
      }
    }
    if (!result && vim.insertMode) vim.status = "";
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
    var vim = this.state.vim;
    var grouped = vim && vim.insertMode;
    if (!grouped) this.history.close();
    this.$applyChange(from, to, text, true, "+input");
    if (!grouped) this.history.close();
    this.$afterDispatch();
  };
  proto.hostSelect = function (flat, primary) {
    var ranges = [];
    for (var i = 0; i + 1 < flat.length; i += 2) ranges.push({ anchor: flat[i], head: flat[i + 1] });
    if (!ranges.length) return;
    var same = ranges.length === this.sel.ranges.length && ranges.every(function (r, k) {
      var c = this.sel.ranges[k];
      return c.anchor === r.anchor && c.head === r.head;
    }, this);
    if (same) return;
    this.$setSel(ranges, primary, true);
    this.$afterDispatch();
  };
  proto.hostSetValue = function (text) {
    var head = this.$primary().head;
    this.doc.setText(text);
    this.history.clear();
    this.marks = Object.create(null);
    var o = Math.min(head, this.doc.getLength());
    this.$setSel([{ anchor: o, head: o }], 0, true);
    this.curOp = null;
    this.$emitState();
  };
  proto.cursorOffset = function () { return this.$primary().head; };
  proto.selectionOffsets = function () {
    var flat = [];
    this.sel.ranges.forEach(function (r) { flat.push(r.anchor, r.head); });
    return flat;
  };
  proto.exec = function (command) {
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
      cm.host.ex(JSON.stringify(payload));
    });
  }

  global.VimKit = {
    Vim: Vim,
    CodeMirror: CodeMirror,
    createEditor: function (host, text, options) {
      var cm = new CodeMirror(host, text, options);
      cm.on("vim-mode-change", function (e) {
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
      cm.curOp = null;
      cm.$emitState();
      return cm;
    },
    defineEx: defineHostEx,
    exec: function (command) {
      // Global commands (:map, :set, ...) need an editor; use a throwaway one.
      var silent = {
        replace: function () {}, select: function () {}, state: function () {}, event: function () {},
        ex: function () {}, coords: function () { return []; }, offsetAt: function () { return -1; },
        scrollInfo: function () { return []; }, scrollTo: function () {}, scrollIntoView: function () {},
        moveVertically: function () { return -1; }, lineBoundary: function () { return -1; },
        lineHeight: function () { return 0; }
      };
      var cm = this.createEditor(silent, "");
      try { Vim.handleEx(cm, command); } finally { cm.destroy(); }
    }
  };
})(this);

// Runs codemirror-vim's own test suite (vim_test.js) against the VimKit adapter.
//
// vim_test.js drives an editor through DOM keyboard events sent to
// document.activeElement. Here those events are routed into the adapter's
// real key path (`handleKeyEvent`), so the suite exercises the same code the
// native text view uses. Text typed in insert mode is inserted the way the
// CodeMirror 6 test page does it (replaceSelection), and Enter/Backspace/
// arrows behave like CodeMirror's default keymap.
(function (global) {
  "use strict";

  var VimKit = global.VimKit;
  var Adapter = VimKit.CodeMirror;
  var current = null;
  var tests = [];
  var results = { done: false, passed: [], failed: [], skipped: [] };

  function noop() {}

  // A small JavaScript lexer standing in for CodeMirror 6's syntax tree, which
  // the reference test page gets from @codemirror/lang-javascript.
  function jsTokens(text) {
    var tokens = [], i = 0, n = text.length;
    while (i < n) {
      var c = text.charAt(i), d = text.charAt(i + 1), start = i;
      if (c == "/" && d == "/") {
        while (i < n && text.charAt(i) != "\n") i++;
        tokens.push({ from: start, to: i, type: "comment" });
      } else if (c == "/" && d == "*") {
        var close = text.indexOf("*/", i + 2);
        i = close < 0 ? n : close + 2;
        tokens.push({ from: start, to: i, type: "comment" });
      } else if (c == "'" || c == '"' || c == "`") {
        i++;
        while (i < n && text.charAt(i) != c && (c == "`" || text.charAt(i) != "\n")) i += text.charAt(i) == "\\" ? 2 : 1;
        if (i < n && text.charAt(i) == c) i++;
        tokens.push({ from: start, to: i, type: "string" });
      } else {
        i++;
      }
    }
    return tokens;
  }

  function makeHost(mode) {
    var cache = null;
    var host = Object.create(headlessHost);
    host.tokenType = function (offset) {
      if (mode == "xml" || !current) return "";
      var text = current.getValue();
      if (!cache || cache.text !== text) cache = { text: text, tokens: jsTokens(text) };
      for (var i = 0; i < cache.tokens.length; i++) {
        var t = cache.tokens[i];
        if (t.from < offset && offset < t.to) return t.type;
        if (t.from >= offset) break;
      }
      return "";
    };
    return host;
  }

  var headlessHost = {
    replace: noop, select: noop, state: noop, event: noop, ex: noop,
    coords: function () { return []; }, offsetAt: function () { return -1; },
    scrollInfo: function () { return []; }, scrollTo: noop, scrollIntoView: noop,
    moveVertically: function () { return -1; }, lineBoundary: function () { return -1; },
    lineHeight: function () { return 0; }
  };

  // ---- DOM pieces the suite touches -------------------------------------------

  var protoNode = Object.getPrototypeOf(document.createElement("div"));
  protoNode.dispatchEvent = function (event) {
    dispatch(this, event);
    return !event.defaultPrevented;
  };
  protoNode.setSelectionRange = function (start, end) {
    this.selectionStart = start;
    this.selectionEnd = end;
  };
  protoNode.getBoundingClientRect = function () { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; };

  var testground = document.createElement("div");
  document.getElementById = function (id) { return id == "testground" ? testground : null; };
  document.body = document.createElement("body");
  Object.defineProperty(document, "activeElement", {
    configurable: true,
    get: function () {
      if (!current) return null;
      if (current.dialog && current.dialog.input) return current.dialog.input;
      return current.inputField;
    }
  });

  function KeyboardEvent(type, data) {
    this.type = type;
    for (var k in data) this[k] = data[k];
    this.defaultPrevented = false;
  }
  KeyboardEvent.prototype.preventDefault = function () { this.defaultPrevented = true; };
  KeyboardEvent.prototype.stopPropagation = function () {};
  global.KeyboardEvent = KeyboardEvent;

  // ---- key routing ------------------------------------------------------------

  function nativeKey(cm, e) {
    var vim = cm.state.vim;
    if (!vim || !vim.insertMode || e.ctrlKey || e.metaKey) return false;
    switch (e.key) {
      case "Backspace": cm.$deleteChar(-1); return true;
      case "Delete": cm.$deleteChar(1); return true;
      case "Enter": Adapter.commands.newlineAndIndent(cm); return true;
      case "Tab": cm.replaceSelection("\t"); return true;
      case "ArrowLeft": Adapter.keys.Left(cm); return true;
      case "ArrowRight": Adapter.keys.Right(cm); return true;
      case "ArrowUp": Adapter.keys.Up(cm); return true;
      case "ArrowDown": Adapter.keys.Down(cm); return true;
      case "Home": case "End":
        var cur = cm.getCursor();
        cm.setCursor(cur.line, e.key == "Home" ? 0 : cm.getLine(cur.line).length);
        return true;
    }
    return false;
  }

  // Like a browser, an exception in a listener is reported, not propagated,
  // and the default action (text input) still happens.
  function dispatch(node, event) {
    var cm = current;
    if (!cm) return;
    var dialog = cm.dialog;
    try {
      if (dialog && node === dialog.input) {
        if (event.type == "keydown") { cm.handleKeyEvent(event); event.preventDefault(); }
        else if (event.type == "input" && dialog.options.onInput) dialog.options.onInput(event, node.value, dialog.close);
      } else if (node === cm.inputField && event.type == "keydown") {
        if (cm.handleKeyEvent(event) || nativeKey(cm, event)) event.preventDefault();
      }
    } catch (e) {
      console.error("listener error: " + e);
    }
  }

  // ---- CodeMirror constructor as vim_test.js expects it ---------------------------

  function CM(place, options) {
    if (current) { current.destroy(); current = null; }
    options = options || {};
    var cm = VimKit.createEditor(makeHost(options.mode), options.value || "", {
      tabSize: options.tabSize || options.indentUnit || 4,
      indentUnit: options.indentUnit || 2,
      indentWithTabs: !!options.indentWithTabs,
      lineWrapping: !!options.lineWrapping,
      lineComment: options.mode == "xml" ? null : "//"
    });
    // The reference page renders into a 420×300 editor.
    cm.setSize(420, 300);
    cm.inputField._handleInputEventForTest = function (text) { cm.replaceSelection(text); };
    current = cm;
    return cm;
  }
  Object.defineProperty(CM, "isMac", {
    get: function () { return Adapter.isMac; },
    set: function (value) { Adapter.isMac = value; },
    configurable: true
  });
  CM.defineMode = noop;
  CM.on = Adapter.on;
  CM.off = Adapter.off;
  CM.Vim = VimKit.Vim;
  CM.Pos = function (line, ch) { return new Adapter.Pos(line, ch); };
  CM.commands = Adapter.commands;
  // Same as codemirror-vim's CodeMirror 6 test page: indent after an open bracket.
  CM.commands.newlineAndIndent = function (cm) {
    var oldCursor = cm.getCursor();
    var oldLine = cm.getLine(oldCursor.line).slice(0, oldCursor.ch);
    var indent = /^\s*/.exec(oldLine)[0];
    if (/[{[(]$/.test(oldLine)) {
      indent += cm.getOption("indentWithTabs") ? "\t" : " ".repeat(cm.getOption("indentUnit"));
    }
    cm.replaceSelection("\n" + indent);
  };

  // ---- runner -------------------------------------------------------------------

  function test(name, fn, expectedFail) {
    tests.push({ name: name, fn: fn, expectedFail: !!expectedFail });
  }

  global.__harness = {
    register: function () { global.vimTests(CM, test); return tests.length; },
    results: results,
    start: function (only) {
      var index = 0;
      var originalIsMac = Adapter.isMac;
      function next() {
        if (index >= tests.length) {
          if (current) { current.destroy(); current = null; }
          results.done = true;
          return;
        }
        var t = tests[index++];
        if (only && only.indexOf(t.name) < 0) { next(); return; }
        Adapter.isMac = originalIsMac;
        var promise;
        try {
          promise = Promise.resolve(t.fn());
        } catch (e) {
          promise = Promise.reject(e);
        }
        promise.then(function () {
          (t.expectedFail ? results.failed : results.passed).push(t.expectedFail ? { name: t.name, message: "passed but marked expectedFail" } : t.name);
        }, function (e) {
          if (t.expectedFail) results.skipped.push(t.name);
          else results.failed.push({ name: t.name, message: String(e && e.message || e) + (e && e.stack ? "\n" + String(e.stack).split("\n").slice(0, 4).join("\n") : "") });
        }).then(function () {
          if (current) { current.destroy(); current = null; }
          setTimeout(next, 0);
        });
      }
      next();
    }
  };
})(this);

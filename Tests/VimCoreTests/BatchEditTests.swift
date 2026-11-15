import Foundation
import Testing
@testable import VimCore

/// Batched paths must behave exactly like the one-change-at-a-time ones:
/// `$applyChanges` vs `$applyChange`, batched undo/redo vs replaying changes,
/// the Swift indent plan vs `$indentPlanJS`, and the line index kept across
/// multi-line edits vs a fresh one.
@MainActor
struct BatchEditTests {
    private func run(_ script: String) -> String {
        let runtime = VimRuntime()
        return runtime.context.evaluateScript(Self.prelude + script)?.toString() ?? "no result"
    }

    private static let prelude = """
    var seed = 12345;
    function rnd(n) { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; }
    function host() { return new Proxy({}, { get: function () { return function () { return null; }; } }); }
    function randomText(lines) {
      var words = ["", "  ", "\\t", "x", "if (a) {", "}", "  b(", "  )", "[", "end", "  q", "ы😀"], out = [];
      for (var i = 0; i < lines; i++) out.push(words[rnd(words.length)] + words[rnd(words.length)]);
      return out.join("\\n");
    }
    function state(cm) {
      var marks = Object.keys(cm.marks).sort().map(function (id) { return id + ":" + cm.marks[id].offset; }).join(",");
      var sel = cm.sel.ranges.map(function (r) { return r.anchor + "-" + r.head; }).join(",");
      return JSON.stringify([cm.getValue(), marks, sel, cm.doc.getLength()]);
    }
    """

    @Test func batchedChangesMatchOneByOne() {
        let result = run("""
        var failure = "ok", batched = 0;
        for (var round = 0; round < 200 && failure == "ok"; round++) {
          var text = randomText(round % 4 ? 150 + rnd(250) : 1 + rnd(40));   // mostly batches of 64+ changes
          var a = VimKit.createEditor(host(), text, {}), b = VimKit.createEditor(host(), text, {});
          var len = text.length, marks = 1 + rnd(20);
          for (var m = 0; m < marks; m++) {
            var at = rnd(len + 1);
            a.setBookmark(a.posFromIndex(at)); b.setBookmark(b.posFromIndex(at));
          }
          var head = rnd(len + 1);
          a.$setSel([{ anchor: head, head: head }], 0); b.$setSel([{ anchor: head, head: head }], 0);
          var changes = [], pos = 0, inserts = ["", "  ", "\\t", "ab", "\\n", "x\\ny", "    "];
          while (pos <= len && changes.length < 3 * 300) {
            var from = pos + rnd(12);
            if (from > len) break;
            var to = Math.min(len, from + rnd(6));
            changes.push(from, to, inserts[rnd(inserts.length)]);
            pos = to + 1 + rnd(3);
          }
          if (round % 4 && changes.length < 3 * 64) continue;
          batched++;
          a.operation(function () { a.$applyChanges(changes, false); });
          b.operation(function () {
            for (var k = 0, shift = 0; k < changes.length; k += 3) {
              b.$applyChange(changes[k] + shift, changes[k + 1] + shift, changes[k + 2], false);
              shift += changes[k + 2].length - (changes[k + 1] - changes[k]);
            }
          });
          b.$historyBatch = function () { return null; };
          if (state(a) !== state(b)) { failure = "apply, round " + round; break; }
          a.undo(); b.undo();
          if (a.getValue() !== text) { failure = "undo text, round " + round; break; }
          if (state(a) !== state(b)) { failure = "undo, round " + round + " " + state(a).slice(-200) + " / " + state(b).slice(-200); break; }
          a.redo(); b.redo();
          if (state(a) !== state(b)) { failure = "redo, round " + round; break; }
        }
        failure == "ok" && batched < 120 ? "only " + batched + " batches" : failure
        """)
        #expect(result == "ok")
    }

    @Test func lineIndexSurvivesMultiLineEdits() {
        let result = run("""
        var failure = "ok";
        for (var round = 0; round < 300 && failure == "ok"; round++) {
          var cm = VimKit.createEditor(host(), randomText(1 + rnd(80)), {});
          for (var step = 0; step < 40; step++) {
            var len = cm.doc.getLength(), from = rnd(len + 1), to = Math.min(len, from + rnd(30));
            var texts = ["", "\\n", "a\\nb", "\\n\\n\\n", "xyz", "q\\n"];
            cm.$applyChange(from, to, texts[rnd(texts.length)], false);
            var probe = rnd(cm.doc.getLength() + 1), fresh = VimKit.createEditor(host(), cm.getValue(), {});
            var p = cm.doc.posFromIndex(probe), q = fresh.doc.posFromIndex(probe);
            if (p.line !== q.line || p.ch !== q.ch || cm.doc.getLength() !== fresh.doc.getLength()) {
              failure = "round " + round + " step " + step; break;
            }
            for (var l = 0; l < cm.doc.lines.length; l++) {
              if (cm.doc.lineStart(l) !== fresh.doc.lineStart(l)) { failure = "line start " + l + ", round " + round; break; }
            }
          }
        }
        failure
        """)
        #expect(result == "ok")
    }

    @Test func swiftIndentPlanMatchesJavaScript() {
        let runtime = VimRuntime()
        let context = runtime.context
        context.evaluateScript(Self.prelude)
        for round in 0..<300 {
            let text = context.evaluateScript("randomText(1 + rnd(150))")!.toString()!
            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let lines = (0..<lineCount).filter { _ in Bool.random() }.map(Int32.init)
            for mode in VimIndentKernel.Mode.allCases {
                for (tab, unit) in [(4, 4), (8, 2), (2, 3), (1, 1)] {
                    context.setObject(text, forKeyedSubscript: "planText" as NSString)
                    context.setObject(lines.map { NSNumber(value: $0) }, forKeyedSubscript: "planLines" as NSString)
                    let js = context.evaluateScript("""
                    Array.from(VimKit.createEditor(host(), planText, {}).$indentPlanJS(planLines, \(mode.rawValue), \(tab), \(unit)))
                    """)!.toArray()!.map { ($0 as! NSNumber).int32Value }
                    let utf16 = Array(text.utf16)
                    let swift = utf16.withUnsafeBufferPointer { buffer in
                        lines.withUnsafeBufferPointer {
                            VimIndentKernel.plan(buffer, lines: $0, mode: mode, tabSize: Int32(tab), unit: Int32(unit))
                        }
                    }
                    #expect(swift == js, "round \(round), mode \(mode), tab \(tab), unit \(unit): \(text.debugDescription)")
                    if swift != js { return }
                }
            }
        }
    }

    @Test func reindentKeepsFoldsMarksAndUndo() {
        let text = (0..<400).map { "func f\($0)() {\n  if x {\n      y\n  }\n}" }.joined(separator: "\n")
        let engine = VimEngine(text: text, runtime: VimRuntime())
        engine.feed("zM")
        let folds = engine.folds.count
        engine.feed("G2kmagg")
        engine.feed("zRzMggVG>")
        #expect(engine.folds.count == folds)
        #expect(engine.text.hasPrefix("    func f0() {\n      if x {"))
        engine.feed("ggVG=")
        #expect(engine.text.hasPrefix("func f0() {\n    if x {\n        y\n    }\n}\nfunc f1"))
        engine.feed("uu")
        #expect(engine.text == text)
        engine.feed("gg'a")
        #expect(engine.status.mode == .normal)
    }
}


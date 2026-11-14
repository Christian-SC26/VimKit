import Foundation
import JavaScriptCore
import Testing
@testable import VimCore

/// Runs codemirror-vim's own test suite (Resources/vim_test.js, ~1,000 cases)
/// against the VimKit adapter. Failures listed in
/// Resources/upstream-known-failures.txt (one test name per line, `#` comments)
/// are tolerated; anything else fails this test, and so does a listed test
/// that started passing (so the list stays accurate).
@MainActor
struct UpstreamSuiteTests {
    @Test(.timeLimit(.minutes(3)))
    func codemirrorVimSuite() async throws {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        var errors: [String] = []
        runtime.log = { level, message in if level == .error { errors.append(message) } }

        let context = runtime.context
        for name in ["vim_test", "upstream-harness"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "js"))
            var source = try String(contentsOf: url, encoding: .utf8)
            source = source.replacingOccurrences(of: "export function vimTests(", with: "function vimTests(")
            context.evaluateScript(source, withSourceURL: url)
        }
        let harness = try #require(context.objectForKeyedSubscript("__harness"))
        let count = harness.invokeMethod("register", withArguments: [])?.toInt32() ?? 0
        #expect(count > 700)

        harness.invokeMethod("start", withArguments: [])
        let results = try #require(harness.objectForKeyedSubscript("results"))
        while results.objectForKeyedSubscript("done")?.toBool() != true {
            try await Task.sleep(for: .milliseconds(5))
        }

        let passed = (results.objectForKeyedSubscript("passed")?.toArray() as? [String]) ?? []
        let failedObjects = (results.objectForKeyedSubscript("failed")?.toArray() as? [[String: Any]]) ?? []
        let failed = failedObjects.compactMap { item -> (String, String)? in
            guard let name = item["name"] as? String else { return nil }
            return (name, item["message"] as? String ?? "")
        }

        let known = try knownFailures()
        let unexpected = failed.filter { !known.contains($0.0) }
        let fixed = known.subtracting(failed.map(\.0))

        let report = """
        codemirror-vim suite: \(passed.count) passed, \(failed.count) failed \
        (\(failed.count - unexpected.count) known) of \(count)
        """
        print(report)
        for (name, message) in unexpected { print("UNEXPECTED FAIL \(name): \(message)") }
        for name in fixed.sorted() { print("NOW PASSING (remove from known list): \(name)") }
        if let path = ProcessInfo.processInfo.environment["VIMKIT_UPSTREAM_REPORT"] {
            let lines = failed.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")
            try lines.write(toFile: path, atomically: true, encoding: .utf8)
        }

        #expect(unexpected.isEmpty, "\(unexpected.count) unexpected failures")
        #expect(fixed.isEmpty, "\(fixed.count) known failures now pass")
    }

    private func knownFailures() throws -> Set<String> {
        let url = try #require(Bundle.module.url(forResource: "upstream-known-failures", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        })
    }
}

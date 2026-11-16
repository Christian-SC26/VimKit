import CryptoKit
import Foundation
import Testing
@testable import VimCore

/// Differential test against real Vim. Tests/Oracle/cases.txt lists keys and
/// starting texts; Tests/Oracle/regenerate.sh plays them in Vim 9 and records
/// the result in Resources/oracle-expected.json. Here VimKit plays the same
/// keys and must end with the same text, cursor, mode and unnamed register.
///
/// Cases listed in Resources/oracle-known-divergences.txt may differ; a listed
/// case that starts matching Vim fails the test, so the list stays accurate.
/// VIMKIT_ORACLE_REPORT=<path> writes every divergence there.
@MainActor
struct OracleTests {
    struct Expected: Decodable {
        var text: [String]
        var line: Int
        var column: Int
        var mode: String
        var register: String
        var registerType: String
        var error: String
    }

    struct Case: Decodable {
        var name: String
        var text: [String]
        var at: [Int]
        var keys: String
        var expected: Expected
    }

    struct Oracle: Decodable {
        var generator: String
        var casesSHA256: String
        var cases: [Case]
    }

    @Test(.timeLimit(.minutes(2)))
    func matchesVim() throws {
        let oracle = try loadOracle()
        #expect(oracle.cases.count > 200)
        try checkFreshness(oracle)

        let known = try knownDivergences()
        var divergences: [(name: String, report: String)] = []
        for item in oracle.cases {
            if let difference = play(item) { divergences.append((item.name, difference)) }
        }

        let unexpected = divergences.filter { !known.contains($0.name) }
        let fixed = known.subtracting(divergences.map(\.name))
        let unknownNames = known.subtracting(oracle.cases.map(\.name))
        print("""
            Vim oracle (\(oracle.generator)): \(oracle.cases.count - divergences.count) of \
            \(oracle.cases.count) cases match, \(divergences.count) differ \
            (\(divergences.count - unexpected.count) known)
            """)
        for item in unexpected { print("UNEXPECTED DIVERGENCE \(item.report)") }
        for name in fixed.subtracting(unknownNames).sorted() { print("NOW MATCHES VIM (remove from known list): \(name)") }
        if let path = ProcessInfo.processInfo.environment["VIMKIT_ORACLE_REPORT"] {
            try divergences.map(\.report).joined(separator: "\n\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        let unexpectedNames = unexpected.map(\.name)
        let nowMatching = fixed.subtracting(unknownNames).sorted()
        let notCases = unknownNames.sorted()
        #expect(unexpectedNames.isEmpty, "cases that differ from Vim (see UNEXPECTED DIVERGENCE above)")
        #expect(nowMatching.isEmpty, "known divergences that now match Vim")
        #expect(notCases.isEmpty, "known divergences that are not cases")
    }

    /// Plays one case in a fresh runtime; nil when VimKit ends like Vim.
    private func play(_ item: Case) -> String? {
        let runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        var errors: [String] = []
        runtime.log = { level, message in if level == .error { errors.append(message) } }
        let vim = VimEngine(text: item.text.joined(separator: "\n"), runtime: runtime)
        vim.setCursor(line: item.at[0] - 1, column: item.at[1] - 1)
        vim.feed(item.keys)
        runtime.firePendingTimers()

        let want = item.expected
        let register = runtime.register("\"")
        let got = Expected(
            text: vim.text.components(separatedBy: "\n"),
            line: vim.cursor.line + 1,
            column: vim.cursor.column + 1,
            mode: Self.vimMode(vim.mode),
            register: register?.text ?? "",
            registerType: register.map(Self.vimRegisterType) ?? "",
            error: vim.status.messageIsError ? vim.status.message ?? "" : ""
        )

        var differences: [String] = []
        func compare<T: Equatable>(_ label: String, _ vimValue: T, _ kitValue: T) {
            if vimValue != kitValue { differences.append("  \(label): Vim \(vimValue) | VimKit \(kitValue)") }
        }
        compare("text", want.text, got.text)
        compare("cursor", "\(want.line):\(want.column)", "\(got.line):\(got.column)")
        compare("mode", want.mode, got.mode)
        compare("register", want.register, got.register)
        // Vim records a block's width ("b3"); VimKit only the kind.
        compare("register type", String(want.registerType.prefix(1)), got.registerType)
        // Errors are compared by number (E486), not wording.
        compare("error", Self.errorCode(want.error), Self.errorCode(got.error))
        for message in errors { differences.append("  JavaScript error: \(message)") }
        guard !differences.isEmpty else { return nil }
        return "[\(item.name)] keys \(item.keys) at \(item.at[0]) \(item.at[1])\n"
            + item.text.map { "  | \($0)" }.joined(separator: "\n") + "\n"
            + differences.joined(separator: "\n")
    }

    private static func vimMode(_ mode: VimMode) -> String {
        switch mode {
        case .normal: "n"
        case .insert: "i"
        case .replace: "R"
        case .visual: "v"
        case .visualLine: "V"
        case .visualBlock: "\u{16}"
        default: mode.rawValue
        }
    }

    private static func vimRegisterType(_ register: VimRegister) -> String {
        switch register.kind {
        case .characterwise: "v"
        case .linewise: "V"
        case .blockwise: "b"
        }
    }

    private static func errorCode(_ message: String) -> String {
        message.isEmpty ? "" : message.firstMatch(of: /E\d+/).map { String($0.output) } ?? "error"
    }

    private func loadOracle() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "oracle-expected", withExtension: "json"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    /// The JSON must come from the current cases.txt (run regenerate.sh).
    private func checkFreshness(_ oracle: Oracle) throws {
        let cases = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oracle/cases.txt")
        guard let data = try? Data(contentsOf: cases) else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == oracle.casesSHA256, "cases.txt changed: run Tests/Oracle/regenerate.sh")
    }

    private func knownDivergences() throws -> Set<String> {
        let url = try #require(Bundle.module.url(forResource: "oracle-known-divergences", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        })
    }
}

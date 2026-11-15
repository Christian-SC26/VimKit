#if os(macOS)
import Foundation

/// Numbered runs kept in the repository (`Benchmarks/history/run-NNN.json`)
/// so every change can be traced: which run, in which language, what changed.
struct History {
    let directory: URL
    /// Run number → file, ascending.
    private(set) var files: [(number: Int, url: URL)]

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { name -> (Int, URL)? in
                guard name.hasPrefix("run-"), name.hasSuffix(".json"),
                      let number = Int(name.dropFirst(4).dropLast(5)) else { return nil }
                return (number, directory.appendingPathComponent(name))
            }
            .sorted { $0.0 < $1.0 }
    }

    var nextNumber: Int { (files.last?.number ?? 0) + 1 }

    func loadAll() -> [BenchRun] {
        let decoder = JSONDecoder()
        return files.compactMap { file in
            (try? Data(contentsOf: file.url)).flatMap { try? decoder.decode(BenchRun.self, from: $0) }
        }
    }

    mutating func save(_ run: BenchRun) throws {
        let number = run.meta.runNumber ?? nextNumber
        let url = directory.appendingPathComponent(String(format: "run-%03d.json", number))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(run).write(to: url)
        files.append((number, url))
    }
}

/// One past run as the report needs it: its meta and per-operation medians.
struct HistoryPoint: Encodable {
    var meta: BenchMeta
    /// "level|lines|category|name" → [wall median ms, main-thread CPU ms, peak MB, instructions].
    var values: [String: [Double]]

    init(_ run: BenchRun) {
        meta = run.meta
        values = Dictionary(run.results.map { ($0.historyKey, [$0.wallMedian, $0.cpuMedian, $0.peakMB, $0.instructionsPerOp]) },
                            uniquingKeysWith: { a, _ in a })
    }
}

extension BenchResult {
    var historyKey: String { "\(level.rawValue)|\(lines)|\(category)|\(name)" }
}

extension BenchRun {
    /// Share of wall time the measured operations spent off the CPU
    /// (waiting for page-ins or for cores other work held).
    var waitShare: Double {
        let ops = results.filter { !$0.lifecycle }
        let wall = ops.reduce(0) { $0 + $1.wallMedian }
        let cpu = ops.reduce(0) { $0 + min($1.cpuMedian, $1.wallMedian) }
        return wall > 0 ? 1 - cpu / wall : 0
    }

    /// Other work competed for CPU or memory: wall times are unreliable.
    var isNoisy: Bool { waitShare > 0.08 || (meta.pageins ?? 0) > 5_000 }

    var loadSummary: String {
        var text = String(format: "ожидание %.0f%%", waitShare * 100)
        if meta.loadAverageStart != nil { text += ", " + meta.loadSummary }
        return text
    }
}

extension BenchMeta {
    var loadSummary: String {
        guard let start = loadAverageStart else { return "—" }
        var text = String(format: "load %.1f→%.1f", start, loadAverageEnd ?? 0)
        if let pageins { text += ", подкачка \(pageins) стр." }
        if let effectiveGHz, effectiveGHz > 0 { text += String(format: ", %.2f ГГц", effectiveGHz) }
        return text
    }

    var mode: String {
        var parts: [String] = []
        if quick { parts.append("--quick") }
        if let filter { parts.append("--filter \(filter)") }
        if sizes != [1_000, 20_000] { parts.append("--sizes " + sizes.map(String.init).joined(separator: ",")) }
        if levels != [.engine, .view] { parts.append("--levels " + levels.map(\.rawValue).joined(separator: ",")) }
        if let foldKernel, foldKernel != "javascript" { parts.append("--fold-kernel \(foldKernel)") }
        return parts.isEmpty ? "полный" : parts.joined(separator: " ")
    }
}

/// Operations followed in HISTORY.md: the most expensive ones in run 1.
private let trackedOperations = [
    "zM (свернуть всё)", ":%norm A;", ":%s/value/item/g", "ggVG> (весь файл)", "ggVG= (весь файл)",
    ":g/note 5/d", "zR (развернуть всё)",
]

/// Fold kernel rows (engine level), compared across languages.
private let trackedKernels = [
    ("foldBlocks(): JavaScript", "ядро: foldBlocks JS"), ("foldBlocks(): Swift", "ядро: foldBlocks Swift"),
    ("foldBlocks(): Goose", "ядро: foldBlocks Goose"), ("чистый расчёт: Swift", "ядро: расчёт Swift"),
    ("чистый расчёт: Goose", "ядро: расчёт Goose"),
]

func writeHistoryMarkdown(_ runs: [BenchRun], to url: URL) throws {
    func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
    func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100 ? String(format: "%.0f", value) : value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }
    let dateIn = ISO8601DateFormatter()
    let dateOut = DateFormatter()
    dateOut.locale = Locale(identifier: "ru_RU")
    dateOut.dateFormat = "dd.MM.yyyy HH:mm"

    var lines = [
        "# История прогонов VimKitBench",
        "",
        "Файл пишет стенд (`swift run -c release VimKitBench --lang <язык> --note \"<что изменилось>\"`)",
        "после каждого прогона, руками не править. Полные результаты — `history/run-NNN.json`,",
        "графики по всем прогонам — в разделе «История» отчёта `bench-results/report.html`.",
        "",
        "Время — медиана на повтор, мс, `VimTextView` в окне, самый большой размер файла в прогоне",
        "(обычно 20 000 строк). «Медиана операций» — медиана медиан всех операций, кроме жизненного цикла.",
        "«Ожидание» — доля стенного времени операций, прошедшая не на процессоре. «⚠︎ шумно» — больше 8%",
        "(машину грузило что-то ещё, подкачка страниц): стенное время такого прогона завышено, сравнивайте CPU",
        "и инструкции в отчёте.",
        "«Ядро: …» — поиск блоков для свёрток (zM) на JavaScript, Swift и Goose, уровень движка: «расчёт» —",
        "только вычисление на готовом UTF-16 буфере, «foldBlocks» — вызов VimEngine.foldBlocks() целиком через мост.",
        "",
    ]
    let header = ["№", "Дата", "Язык", "Что изменилось", "Коммит", "Сборка, режим", "Нагрузка системы", "Прогон, с"]
        + trackedOperations + ["Медиана операций"] + trackedKernels.map(\.1)
    lines.append("| " + header.map(cell).joined(separator: " | ") + " |")
    lines.append("|" + header.map { _ in "---" }.joined(separator: "|") + "|")
    for run in runs {
        let meta = run.meta
        let ops = run.results.filter { !$0.lifecycle && $0.category != "Стенд" && $0.category != "Ядро свёрток" }
        let level: Level = ops.contains { $0.level == .view } ? .view : .engine
        let size = ops.filter { $0.level == level }.map(\.lines).max() ?? 0
        let selected = ops.filter { $0.level == level && $0.lines == size }
        let medians = selected.map(\.wallMedian).sorted()
        let overall = medians.isEmpty ? nil : medians[medians.count / 2]
        let date = dateIn.date(from: meta.date).map(dateOut.string(from:)) ?? meta.date
        var row = [
            meta.runNumber.map(String.init) ?? "—", date, meta.language ?? "—", meta.note ?? "—", meta.commit,
            "\(meta.build), \(meta.mode)" + (size != 20_000 && size > 0 ? ", \(size) строк" : "") + (level == .engine ? ", движок" : ""),
            (run.isNoisy ? "⚠︎ шумно: " : "") + run.loadSummary,
            String(format: "%.0f", meta.durationSeconds),
        ]
        row += trackedOperations.map { name in ms(selected.first { $0.name == name }?.wallMedian) }
        row.append(ms(overall))
        let kernelRows = run.results.filter { $0.category == "Ядро свёрток" && $0.level == .engine && $0.lines == size }
        row += trackedKernels.map { name, _ in ms(kernelRows.first { $0.name == name }?.wallMedian) }
        lines.append("| " + row.map(cell).joined(separator: " | ") + " |")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}
#endif

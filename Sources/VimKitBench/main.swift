#if os(macOS)
import AppKit
import Foundation

let options = BenchOptions.parse(CommandLine.arguments)
NSApplication.shared.setActivationPolicy(.prohibited)

#if DEBUG
let buildConfiguration = "debug"
FileHandle.standardError.write(Data("⚠︎ Отладочная сборка: цифры завышены. Запускайте `swift run -c release VimKitBench`.\n".utf8))
#else
let buildConfiguration = "release"
#endif

let started = Date()
let baseFootprint = Double(Probe.rusage().ri_phys_footprint) / 1_048_576
let loadAtStart = Probe.loadAverage()
let runner = Runner(options: options)
runner.runAll()

func shell(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

var history = try History(directory: URL(fileURLWithPath: options.historyDirectory, isDirectory: true))
let pastRuns = history.loadAll()
let formatter = ISO8601DateFormatter()
let version = ProcessInfo.processInfo.operatingSystemVersion
var commit = shell(["git", "rev-parse", "--short", "HEAD"]) ?? "—"
if let status = shell(["git", "status", "--porcelain", "--untracked-files=no"]), !status.isEmpty { commit += "+изменения" }
let meta = BenchMeta(
    date: formatter.string(from: started),
    chip: Probe.sysctlString("machdep.cpu.brand_string") ?? "—",
    model: Probe.sysctlString("hw.model") ?? "—",
    performanceCores: Int(Probe.sysctlInt("hw.perflevel0.physicalcpu")),
    efficiencyCores: Int(Probe.sysctlInt("hw.perflevel1.physicalcpu")),
    memoryGB: Double(Probe.sysctlInt("hw.memsize")) / 1_073_741_824,
    os: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
    build: buildConfiguration,
    commit: commit,
    sizes: options.sizes,
    levels: options.levels,
    quick: options.quick,
    durationSeconds: Date().timeIntervalSince(started),
    baseFootprintMB: baseFootprint,
    nanojoulesPerCycle: runner.nanojoulesPerCycle,
    averagePowerW: runner.averagePowerW,
    runNumber: history.nextNumber,
    language: options.language,
    note: options.note,
    filter: options.filter,
    foldKernel: options.foldKernel.rawValue,
    loadAverageStart: loadAtStart,
    loadAverageEnd: Probe.loadAverage(),
    pageins: runner.totalPageins,
    effectiveGHz: runner.effectiveGHz
)
let run = BenchRun(meta: meta, results: runner.results)

// MARK: Files

let fileManager = FileManager.default
let outURL = URL(fileURLWithPath: options.outDirectory, isDirectory: true)
try fileManager.createDirectory(at: outURL, withIntermediateDirectories: true)

// The baseline: an explicit file, or the newest earlier run in the history
// with the same build configuration and the same quick/full mode.
var baseline: BenchRun?
if let path = options.baseline {
    baseline = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(BenchRun.self, from: $0) }
    if baseline == nil { FileHandle.standardError.write(Data("Не удалось прочитать базовый прогон \(path)\n".utf8)) }
} else {
    baseline = pastRuns.last { $0.meta.build == meta.build && $0.meta.quick == meta.quick }
}

try history.save(run)
let allRuns = pastRuns + [run]
let historyMarkdown = history.directory.deletingLastPathComponent().appendingPathComponent("HISTORY.md")
try writeHistoryMarkdown(allRuns, to: historyMarkdown)

struct ReportData: Encodable {
    var run: BenchRun
    var baseline: BenchRun?
    var history: [HistoryPoint]
}
let reportJSON = String(decoding: try JSONEncoder().encode(ReportData(run: run, baseline: baseline, history: allRuns.map(HistoryPoint.init))),
                        as: UTF8.self)
    .replacingOccurrences(of: "</", with: "<\\/")
let reportURL = outURL.appendingPathComponent("report.html")
try reportTemplate.replacingOccurrences(of: "__BENCH_DATA__", with: reportJSON)
    .write(to: reportURL, atomically: true, encoding: .utf8)

// MARK: Console summary

if run.isNoisy {
    print("⚠︎ Во время прогона была внешняя нагрузка (\(run.loadSummary)). Стенное время ненадёжно — сравнивайте CPU и инструкции.")
}

print("\nVimKitBench · прогон №\(meta.runNumber ?? 0) · \(meta.language ?? "—") · \(meta.chip) · \(meta.os) · \(meta.build) · \(meta.commit) · \(String(format: "%.0f", meta.durationSeconds)) с")
let slow = run.results.filter { !$0.lifecycle && $0.wallP95 > 1000.0 / 60 }
if !slow.isEmpty {
    print("Не укладываются в кадр 16,7 мс (p95):")
    for result in slow.sorted(by: { $0.wallP95 > $1.wallP95 }) {
        print(String(format: "  %-6@ %6d  %-40@ p95 %9.2f мс", result.level.rawValue as NSString, result.lines,
                     result.name as NSString, result.wallP95))
    }
}
let broken = run.results.filter { !$0.inSync || $0.jsErrors > 0 }
for result in broken {
    print("⚠︎ \(result.level.rawValue) \(result.lines) \(result.name): синхрон \(result.inSync), ошибок JS \(result.jsErrors) \(result.firstError ?? "")")
}
if let baseline {
    let previous = Dictionary(baseline.results.map { ("\($0.level)|\($0.lines)|\($0.category)|\($0.name)", $0) },
                              uniquingKeysWith: { a, _ in a })
    let regressions = run.results.compactMap { result -> (BenchResult, Double)? in
        guard let old = previous["\(result.level)|\(result.lines)|\(result.category)|\(result.name)"],
              old.wallMedian > 0, result.wallMedian - old.wallMedian > 0.05 else { return nil }
        let change = result.wallMedian / old.wallMedian - 1
        // Same instructions but more time is the machine (frequency, thermals, load), not the code.
        let instructions = old.instructionsPerOp > 0 ? result.instructionsPerOp / old.instructionsPerOp - 1 : 0
        return change > 0.15 && instructions > 0.05 ? (result, change) : nil
    }
    print("Сравнение с прогоном №\(baseline.meta.runNumber ?? 0), \(baseline.meta.date) (\(baseline.meta.commit)): медленнее на 15%+ и больше инструкций — \(regressions.count)")
    for (result, change) in regressions.sorted(by: { $0.1 > $1.1 }).prefix(15) {
        print(String(format: "  %-6@ %6d  %-40@ %+6.0f%%", result.level.rawValue as NSString, result.lines,
                     result.name as NSString, change * 100))
    }
}
print("JSON:    \(history.files.last!.url.path)")
print("История: \(historyMarkdown.path)")
print("Отчёт: \(reportURL.path)")
if options.openReport { NSWorkspace.shared.open(reportURL) }
#else
print("VimKitBench работает только на macOS.")
#endif

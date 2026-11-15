#if os(macOS)
import AppKit
import Foundation
import VimCore
import VimKit

struct BenchResult: Codable, Sendable {
    var category: String
    var name: String
    var keys: String
    var level: Level
    var lines: Int
    var lifecycle: Bool
    var repeats: Int
    /// Wall time per repeat, ms.
    var wallFirst: Double
    var wallMedian: Double
    var wallP95: Double
    var wallMax: Double
    var wallMean: Double
    /// CPU time of the main thread per repeat (median), ms.
    var cpuMedian: Double
    /// CPU time of the whole process per repeat (all threads, incl. JS GC), ms.
    var processCpuPerOp: Double
    var instructionsPerOp: Double
    var cyclesPerOp: Double
    /// Estimated energy per repeat, µJ: cycles × the process's energy per cycle over the whole run.
    var energyPerOpUJ: Double
    /// Highest footprint during the timed repeats above the footprint at start, MB.
    var peakMB: Double
    /// Footprint after all repeats minus footprint at start, MB.
    var retainedMB: Double
    /// Same as `retainedMB` divided by repeats (meaningful for lifecycle rows that keep instances).
    var retainedPerRepeatMB: Double
    /// Change in bytes allocated through malloc, KB.
    var mallocKB: Double
    var pageins: Int
    var wakeups: Int
    /// Repeats slower than one 60 Hz frame (16.7 ms).
    var hitches: Int
    var inSync: Bool
    var jsErrors: Int
    var firstError: String?
}

struct BenchMeta: Codable, Sendable {
    var date: String
    var chip: String
    var model: String
    var performanceCores: Int
    var efficiencyCores: Int
    var memoryGB: Double
    var os: String
    var build: String
    var commit: String
    var sizes: [Int]
    var levels: [Level]
    var quick: Bool
    var durationSeconds: Double
    var baseFootprintMB: Double
    var nanojoulesPerCycle: Double?
    var averagePowerW: Double?
    /// Sequential number in `Benchmarks/history`.
    var runNumber: Int?
    /// Language the measured change was written in (JS, Swift, Goose, …).
    var language: String?
    /// What changed since the previous run.
    var note: String?
    var filter: String?
}

struct BenchRun: Codable, Sendable {
    var meta: BenchMeta
    var results: [BenchResult]
}

struct BenchOptions {
    var sizes = [1_000, 20_000]
    var levels: [Level] = [.engine, .view]
    var filter: String?
    var quick = false
    var outDirectory = "bench-results"
    var baseline: String?
    var openReport = true
    var language = "JS"
    var note: String?
    var historyDirectory = "Benchmarks/history"

    static func parse(_ arguments: [String]) -> BenchOptions {
        var options = BenchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--sizes":
                options.sizes = (iterator.next() ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            case "--levels":
                options.levels = (iterator.next() ?? "").split(separator: ",").compactMap { Level(rawValue: String($0)) }
            case "--filter": options.filter = iterator.next()
            case "--quick": options.quick = true
            case "--out": options.outDirectory = iterator.next() ?? options.outDirectory
            case "--baseline": options.baseline = iterator.next()
            case "--no-open": options.openReport = false
            case "--lang": options.language = iterator.next() ?? options.language
            case "--note": options.note = iterator.next()
            case "--history": options.historyDirectory = iterator.next() ?? options.historyDirectory
            case "-h", "--help":
                print("""
                VimKitBench — стенд производительности VimKit.

                  swift run -c release VimKitBench [параметры]

                  --sizes 1000,20000      размеры документа в строках
                  --levels engine,view    уровни: движок без UI и VimTextView в окне
                  --filter текст          только операции, в имени или категории которых есть текст
                  --quick                 вчетверо меньше повторов
                  --out каталог           куда писать JSON и отчёт (bench-results)
                  --lang язык             на каком языке сделано изменение: JS, Swift, Goose… (JS)
                  --note "текст"          что изменилось с прошлого прогона
                  --history каталог       история прогонов с номерами (Benchmarks/history)
                  --baseline файл.json    с чем сравнивать (по умолчанию — предыдущий
                                          прогон из истории с той же сборкой и режимом)
                  --no-open               не открывать отчёт в браузере
                """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("Неизвестный параметр \(argument), см. --help\n".utf8))
                exit(2)
            }
        }
        return options
    }
}

@MainActor
final class Runner {
    let options: BenchOptions
    let sampler = FootprintSampler()
    let runtime: VimRuntime
    private(set) var results: [BenchResult] = []
    private var jsErrors = 0
    private var firstError: String?
    private var step = 0
    private var totalSteps = 0
    private var runStart = Probe.rusage()
    /// Energy the kernel billed per CPU cycle over the whole run, nJ.
    private(set) var nanojoulesPerCycle = 0.0
    /// Average power of the process while the bench ran, W.
    private(set) var averagePowerW = 0.0

    init(options: BenchOptions) {
        self.options = options
        runtime = VimRuntime()
        runtime.clipboard = InMemoryClipboard()
        runtime.log = { [weak self] level, message in
            guard level >= .warning, let self else { return }
            self.jsErrors += 1
            if self.firstError == nil { self.firstError = String(message.prefix(300)) }
        }
    }

    func runAll() {
        let selected = scenarios.filter { scenario in
            guard let filter = options.filter?.lowercased() else { return true }
            return scenario.name.lowercased().contains(filter) || scenario.category.lowercased().contains(filter)
        }
        let lifecycleSteps = options.filter == nil ? 1 + options.sizes.count * 6 : 0
        totalSteps = lifecycleSteps + selected.count * options.sizes.count * options.levels.count
        runStart = Probe.rusage()
        let wallStart = Probe.wallNanoseconds
        defer { estimateEnergy(wallStart: wallStart) }
        if options.filter == nil { runLifecycle() }
        for lines in options.sizes {
            let text = sampleCode(lines: lines)
            for level in options.levels {
                for scenario in selected {
                    let document: any BenchDocument = level == .engine
                        ? EngineDocument(text: text, runtime: runtime)
                        : ViewDocument(text: text, runtime: runtime)
                    document.type(scenario.setup)
                    record(measure(
                        category: scenario.category, name: scenario.name, keys: scenario.keys,
                        level: level, lines: lines, lifecycle: false, repeats: repeats(scenario.repeats),
                        operation: document.player(scenario.keys),
                        between: document.player(scenario.between),
                        check: { document.inSync }
                    ))
                    document.close()
                    // Let deferred work (window teardown, JS timers) settle between scenarios.
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
                }
            }
        }
    }

    /// The kernel bills energy to the process lazily (roughly every few ms of
    /// CPU), so sub-millisecond operations read as zero. Instead, take the
    /// energy and cycles of the whole run and charge each operation for its cycles.
    private func estimateEnergy(wallStart: UInt64) {
        let end = Probe.rusage()
        var total = Usage()
        total.add(from: runStart, to: end)
        guard total.cycles > 0, total.energy > 0 else { return }
        nanojoulesPerCycle = Double(total.energy) / Double(total.cycles)
        averagePowerW = Double(total.energy) / Double(Probe.wallNanoseconds - wallStart)
        for index in results.indices {
            results[index].energyPerOpUJ = results[index].cyclesPerOp * nanojoulesPerCycle / 1e3
        }
    }

    private func repeats(_ count: Int) -> Int {
        options.quick ? max(1, count / 4) : count
    }

    // MARK: Lifecycle

    private func runLifecycle() {
        let category = "Жизненный цикл"
        var runtimes: [VimRuntime] = []
        record(measure(category: category, name: "VimRuntime: JSContext + загрузка vim.js", keys: "",
                       level: .engine, lines: 0, lifecycle: true, repeats: repeats(8),
                       operation: { runtimes.append(VimRuntime()) }))
        runtimes.removeAll()

        for lines in options.sizes {
            let text = sampleCode(lines: lines)
            let otherText = text + "\n// changed"

            var engines: [VimEngine] = []
            record(measure(category: category, name: "Создание VimEngine с текстом", keys: "",
                           level: .engine, lines: lines, lifecycle: true, repeats: repeats(8),
                           operation: { [runtime] in engines.append(VimEngine(text: text, runtime: runtime)) }))
            engines.removeAll()

            let engine = VimEngine(text: text, runtime: runtime)
            var flip = false
            record(measure(category: category, name: "VimEngine.setText (весь документ)", keys: "",
                           level: .engine, lines: lines, lifecycle: true, repeats: repeats(8),
                           operation: {
                               flip.toggle()
                               engine.setText(flip ? otherText : text)
                           }))
            record(measure(category: category, name: "Чтение VimEngine.text (JS → Swift)", keys: "",
                           level: .engine, lines: lines, lifecycle: true, repeats: repeats(20),
                           operation: { _ = engine.text.utf16.count }))

            var views: [ViewDocument] = []
            record(measure(category: category, name: "Создание VimTextView в окне + раскладка", keys: "",
                           level: .view, lines: lines, lifecycle: true, repeats: repeats(4),
                           operation: { [runtime] in views.append(ViewDocument(text: text, runtime: runtime)) }))
            views.forEach { $0.close() }
            views.removeAll()

            var document = ViewDocument(text: text, runtime: runtime)
            let jump = KeyEvents.parse("G")
            record(measure(category: category, name: "Первый G в новой вьюхе (раскладка до конца)", keys: "G",
                           level: .view, lines: lines, lifecycle: true, repeats: repeats(4),
                           operation: {
                               for event in jump { document.view.keyDown(with: event) }
                               document.window.displayIfNeeded()
                           },
                           between: { [runtime] in
                               document.close()
                               document = ViewDocument(text: text, runtime: runtime)
                           },
                           check: { document.inSync }))
            document.close()

            let typing = ViewDocument(text: text, runtime: runtime)
            typing.type("50%ji")
            record(measure(category: category, name: "Вставка 1 КБ текста во вьюху (paste)", keys: "",
                           level: .view, lines: lines, lifecycle: true, repeats: repeats(20),
                           operation: {
                               typing.view.insertText(String(repeating: "let pasted = 1\n", count: 68),
                                                      replacementRange: typing.view.selectedRange())
                               typing.window.displayIfNeeded()
                           },
                           check: { typing.inSync }))
            typing.close()
        }
    }

    // MARK: Measurement

    private func measure(
        category: String, name: String, keys: String, level: Level, lines: Int, lifecycle: Bool, repeats: Int,
        operation: @MainActor () -> Void, between: @MainActor () -> Void = {}, check: @MainActor () -> Bool = { true }
    ) -> BenchResult {
        jsErrors = 0
        firstError = nil
        var wall: [Double] = []
        var cpu: [Double] = []
        wall.reserveCapacity(repeats)
        cpu.reserveCapacity(repeats)
        var usage = Usage()

        let mallocStart = Probe.mallocInUse()
        let usageStart = Probe.rusage()
        let footprintStart = usageStart.ri_phys_footprint
        sampler.begin(baseline: footprintStart)
        for index in 0..<repeats {
            let before = Probe.rusage()
            let cpu0 = Probe.threadCPUNanoseconds
            let wall0 = Probe.wallNanoseconds
            operation()
            let wall1 = Probe.wallNanoseconds
            let cpu1 = Probe.threadCPUNanoseconds
            let after = Probe.rusage()
            sampler.observe(after.ri_phys_footprint)
            usage.add(from: before, to: after)
            wall.append(Double(wall1 - wall0) / 1e6)
            cpu.append(Double(cpu1 - cpu0) / 1e6)
            if index < repeats - 1 {
                sampler.setActive(false)
                between()
                sampler.setActive(true)
            }
        }
        let peak = sampler.end()
        let footprintEnd = Probe.rusage().ri_phys_footprint
        let mallocEnd = Probe.mallocInUse()

        let sortedWall = wall.sorted()
        let sortedCPU = cpu.sorted()
        let n = Double(repeats)
        let megabyte = 1_048_576.0
        let retained = (Double(footprintEnd) - Double(footprintStart)) / megabyte
        return BenchResult(
            category: category, name: name, keys: keys, level: level, lines: lines, lifecycle: lifecycle,
            repeats: repeats,
            wallFirst: wall.first ?? 0,
            wallMedian: percentile(sortedWall, 0.5),
            wallP95: percentile(sortedWall, 0.95),
            wallMax: sortedWall.last ?? 0,
            wallMean: wall.reduce(0, +) / n,
            cpuMedian: percentile(sortedCPU, 0.5),
            processCpuPerOp: Double(usage.processCPU) / 1e6 / n,
            instructionsPerOp: Double(usage.instructions) / n,
            cyclesPerOp: Double(usage.cycles) / n,
            energyPerOpUJ: 0, // filled in by `estimateEnergy()` once the whole run is known
            peakMB: max(0, (Double(peak) - Double(footprintStart)) / megabyte),
            retainedMB: retained,
            retainedPerRepeatMB: retained / n,
            mallocKB: (Double(mallocEnd) - Double(mallocStart)) / 1024,
            pageins: Int(usage.pageins),
            wakeups: Int(usage.wakeups),
            hitches: wall.filter { $0 > 1000.0 / 60 }.count,
            inSync: check(),
            jsErrors: jsErrors,
            firstError: firstError
        )
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if p == 0.5 {
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
        let index = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func record(_ result: BenchResult) {
        results.append(result)
        step += 1
        let flag = result.inSync ? "" : "  ⚠︎ рассинхрон"
        let errors = result.jsErrors > 0 ? "  ⚠︎ ошибок JS: \(result.jsErrors)" : ""
        let line = String(format: "[%3d/%d] %-6@ %6d  %-44@ %9.3f мс  CPU %8.3f мс%@%@\n",
                          step, totalSteps, result.level.rawValue as NSString, result.lines,
                          String(result.name.prefix(44)) as NSString, result.wallMedian, result.cpuMedian,
                          flag as NSString, errors as NSString)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
#endif

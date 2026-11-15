import Darwin
import Foundation
import os

/// Process and thread counters read around every measured operation.
enum Probe {
    /// `ri_user_time` / `ri_system_time` are in Mach ticks on Apple silicon.
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * timebase.numer / timebase.denom
    }

    static func rusage() -> rusage_info_v6 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return info
    }

    static var wallNanoseconds: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static var threadCPUNanoseconds: UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Bytes currently allocated through malloc in all zones.
    static func mallocInUse() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.size_in_use)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func sysctlInt(_ name: String) -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }
}

/// Resource usage accumulated over the timed part of a scenario.
struct Usage {
    var processCPU: UInt64 = 0
    var instructions: UInt64 = 0
    var cycles: UInt64 = 0
    var energy: UInt64 = 0
    var pageins: UInt64 = 0
    var wakeups: UInt64 = 0

    mutating func add(from a: rusage_info_v6, to b: rusage_info_v6) {
        func delta(_ x: UInt64, _ y: UInt64) -> UInt64 { y >= x ? y - x : 0 }
        processCPU += Probe.ticksToNanoseconds(delta(a.ri_user_time + a.ri_system_time, b.ri_user_time + b.ri_system_time))
        instructions += delta(a.ri_instructions, b.ri_instructions)
        cycles += delta(a.ri_cycles, b.ri_cycles)
        energy += delta(a.ri_energy_nj, b.ri_energy_nj)
        pageins += delta(a.ri_pageins, b.ri_pageins)
        wakeups += delta(a.ri_interrupt_wkups + a.ri_pkg_idle_wkups, b.ri_interrupt_wkups + b.ri_pkg_idle_wkups)
    }
}

/// Samples the process memory footprint on a background thread so short
/// spikes inside an operation (JS garbage, layout buffers) are seen.
final class FootprintSampler: Sendable {
    private struct State: Sendable {
        var active = false
        var peak: UInt64 = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(intervalMicroseconds: UInt32 = 500) {
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        let thread = Thread {
            while true {
                let footprint = Probe.rusage().ri_phys_footprint
                state.withLock { if $0.active { $0.peak = max($0.peak, footprint) } }
                usleep(intervalMicroseconds)
            }
        }
        thread.name = "VimKitBench footprint sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func begin(baseline: UInt64) {
        state.withLock { $0 = State(active: true, peak: baseline) }
    }

    func setActive(_ active: Bool) {
        state.withLock { $0.active = active }
    }

    func observe(_ footprint: UInt64) {
        state.withLock { $0.peak = max($0.peak, footprint) }
    }

    func end() -> UInt64 {
        state.withLock {
            $0.active = false
            return $0.peak
        }
    }
}

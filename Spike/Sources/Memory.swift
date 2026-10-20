import Foundation

/// Process memory as the system accounts it (`phys_footprint`, what jetsam looks at) and a sampler that keeps the peak.
enum Memory {
    private static func taskInfo<Info>(_ flavor: Int32, _ info: inout Info) -> Bool {
        var count = mach_msg_type_number_t(MemoryLayout<Info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(flavor), $0, &count) }
        }
        return result == KERN_SUCCESS
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        return taskInfo(TASK_VM_INFO, &info) ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Resident set size: pages currently in RAM, including mapped model files that `phys_footprint` can leave out.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        return taskInfo(MACH_TASK_BASIC_INFO, &info) ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// Bytes the system would still let this process allocate before jetsam (nil off-device).
    static func availableMB() -> Double? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_048_576 : nil
    }
}

/// Polls the footprint on a background queue so a short peak (model load, compile) is not missed.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = Memory.footprintMB()
    private var peakResident = Memory.residentMB()
    private var minAvailable = Memory.availableMB()
    private var running = true

    init(intervalMs: Int = 25) {
        let queue = DispatchQueue(label: "spike.peak", qos: .utility)
        queue.async { [weak self] in
            while let self, self.isRunning {
                self.record(Memory.footprintMB(), resident: Memory.residentMB(), available: Memory.availableMB())
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func record(_ value: Double, resident: Double, available: Double?) {
        lock.lock()
        peak = max(peak, value)
        peakResident = max(peakResident, resident)
        if let available { minAvailable = min(minAvailable ?? available, available) }
        lock.unlock()
    }

    /// Highest resident size seen.
    var peakResidentMB: Double {
        lock.lock()
        defer { lock.unlock() }
        return max(peakResident, Memory.residentMB())
    }

    /// Lowest jetsam headroom seen (nil off-device).
    var minAvailableMB: Double? {
        lock.lock()
        defer { lock.unlock() }
        return minAvailable
    }

    var peakMB: Double {
        lock.lock()
        defer { lock.unlock() }
        return max(peak, Memory.footprintMB())
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

}

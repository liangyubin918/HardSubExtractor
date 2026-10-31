import Darwin
import Foundation

/// 进程内存探针。phys_footprint 就是活动监视器里显示的那个数字。
enum MemoryProbe {

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static var observedPeak: Double = 0

    /// 当前物理内存占用（MB）
    static func currentMB() -> Double {
        guard let info = vmInfo() else { return -1 }
        let value = Double(info.phys_footprint) / 1024 / 1024
        if value > observedPeak { observedPeak = value }
        return value
    }

    /// 本次进程观察到的峰值（MB）
    static func peakMB() -> Double {
        _ = currentMB()
        return observedPeak
    }

    static func describe() -> String {
        String(format: "内存 当前 %.0f MB / 峰值 %.0f MB", currentMB(), peakMB())
    }
}

import Foundation

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JIT {
    /// True when the process is marked CS_DEBUGGED, which is what LiveContainer/StikDebug JIT sets.
    static var isEnabled: Bool {
        var flags: UInt32 = 0
        let r = csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size)
        return r == 0 && (flags & 0x10000000 /* CS_DEBUGGED */) != 0
    }
}

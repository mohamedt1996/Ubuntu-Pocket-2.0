import Foundation

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JIT {
    /// True when the process is marked CS_DEBUGGED (set by StikDebug / LiveContainer JIT).
    static var isEnabled: Bool {
        var flags: UInt32 = 0
        let r = csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size)
        return r == 0 && (flags & 0x10000000 /* CS_DEBUGGED */) != 0
    }

    /// iOS 26+ on A15 and newer (your A16 included) enforces TXM, so executable memory
    /// has to come from the StikDebug universal.js script.
    static var needsScript: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
}

/// Requests the JIT code region from StikDebug's universal.js right after launch.
final class JITRegion: ObservableObject {
    static let shared = JITRegion()
    static let sizeMB = 256

    enum Status: Equatable { case waiting, notNeeded, ready, noDebugger, crashedLastTime, failed(String) }
    @Published private(set) var status: Status = .waiting

    private let guardKey = "jit26.inProgress"

    var isReady: Bool { jit26_is_ready() != 0 }

    func prepareAtLaunch() {
        guard JIT.needsScript else { status = .notNeeded; return }
        let d = UserDefaults.standard
        if d.bool(forKey: guardKey) {
            // The previous attempt crashed (no universal.js attached). Don't loop.
            d.set(false, forKey: guardKey)
            status = .crashedLastTime
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait up to 10 s for the debugger to attach
            var waited = 0
            while !JIT.isEnabled && waited < 100 { usleep(100_000); waited += 1 }
            guard JIT.isEnabled else { self.set(.noDebugger); return }

            d.set(true, forKey: self.guardKey); d.synchronize()
            var buf = [CChar](repeating: 0, count: 256)
            let rc = jit26_prepare(JITRegion.sizeMB << 20, &buf, buf.count)
            d.set(false, forKey: self.guardKey); d.synchronize()
            self.set(rc == 0 ? .ready : .failed(String(cString: buf)))
        }
    }

    private func set(_ s: Status) { DispatchQueue.main.async { self.status = s } }
}

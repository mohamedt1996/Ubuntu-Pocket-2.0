import Foundation
import Darwin

/// Boots Debian 13 (arm64) inside QEMU running in this same process.
/// The guest serial console uses a dedicated socket pair, independent of host stdio.
final class VMManager: ObservableObject {
    static let shared = VMManager()

    enum State: Equatable { case stopped, preparing, booting, running, failed(String) }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lastLog: String?

    private var serialGuestFD: Int32 = -1
    private var launchAttempted = false
    private var bootPhase = "not started"
    private var guestOutputSeen = false // accessed on the main queue
    private var guestInput: Int32 = -1          // app end of the serial socket
    private var outputHandle: FileHandle?       // reads the same full-duplex socket
    private var sink: ((ArraySlice<UInt8>) -> Void)?
    private var pending = [UInt8]()
    private let writeQueue = DispatchQueue(label: "vm.serial.write")

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var diskURL: URL { docs.appendingPathComponent("debian-disk.qcow2") }
    private var logURL: URL { docs.appendingPathComponent("qemu.log") }
    private var serialLogURL: URL { docs.appendingPathComponent("serial.log") }
    private var cpuLogURL: URL { docs.appendingPathComponent("cpu-trace.log") }
    private var serialShown: UInt64 = 0
    private var vmBundleDir: URL { Bundle.main.bundleURL.appendingPathComponent("VM") }

    private init() {
        lastLog = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(4000)) }
    }

    // MARK: Terminal plumbing

    func attach(_ sink: @escaping (ArraySlice<UInt8>) -> Void) {
        self.sink = sink
        if !pending.isEmpty { sink(pending[...]); pending.removeAll() }
    }

    /// Feed bytes to the terminal (or buffer until it is attached). Main thread only.
    private func emit(_ bytes: [UInt8]) {
        if let s = sink { s(bytes[...]) } else { pending += bytes }
    }

    private func emitNote(_ text: String) {
        let t = "\u{1b}[33m" + text.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[0m"
        DispatchQueue.main.async { self.emit(Array(t.utf8)) }
    }

    private var logTimer: DispatchSourceTimer?
    private var logOffset: UInt64 = 0
    private var bootStart = Date()
    private var lastHeartbeat = -1

    /// Copies new QEMU warnings/errors from qemu.log into the terminal in yellow,
    /// and prints a heartbeat until the guest says anything.
    private func startLogMirror() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            if let h = try? FileHandle(forReadingFrom: self.logURL) {
                h.seek(toFileOffset: self.logOffset)
                let d = h.readDataToEndOfFile()
                try? h.close()
                if !d.isEmpty {
                    self.logOffset += UInt64(d.count)
                    self.emitNote(String(decoding: d, as: UTF8.self))
                }
            }
            let secs = Int(Date().timeIntervalSince(self.bootStart))
            let serialSize = self.fileSize(self.serialLogURL)
            // If Linux is writing to the serial log but nothing reached the terminal socket,
            // show the log file instead so you can still read the boot.
            if !self.guestOutputSeen && serialSize > self.serialShown && secs >= 5,
               let h = try? FileHandle(forReadingFrom: self.serialLogURL) {
                h.seek(toFileOffset: self.serialShown)
                let d = h.readDataToEndOfFile(); try? h.close()
                self.serialShown += UInt64(d.count)
                let text = String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
                DispatchQueue.main.async { self.emit(Array(text.utf8)) }
            }
            if secs > 0 && secs / 10 != self.lastHeartbeat && secs >= 10 && secs <= 300 && !self.guestOutputSeen {
                self.lastHeartbeat = secs / 10
                let handed: String = jit26_handed() != 0 ? "yes" : "NO"
                let serialText: String = self.human(serialSize)
                let cpuText: String = self.human(self.fileSize(self.cpuLogURL))
                let line: String = "[Debian Pocket] \(secs)s [\(self.bootPhase)]: serial.log " + serialText
                    + ", qemu-debug " + cpuText + ", code buffer used: " + handed + "\n"
                self.emitNote(line)
            }
        }
        t.resume()
        logTimer = t
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private func human(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1_048_576 { return "\(n / 1024) KB" }
        return "\(n / 1_048_576) MB"
    }

    func send(_ data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let fd = guestInput
        guard fd >= 0 else { return }
        writeQueue.async {
            bytes.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    off += n
                }
            }
        }
    }

    // MARK: Disk

    func resetDisk() {
        try? FileManager.default.removeItem(at: diskURL)
    }

    private func prepareDisk() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: diskURL.path) { return }
        let src = vmBundleDir.appendingPathComponent("disk.qcow2")
        guard fm.fileExists(atPath: src.path) else { throw err("disk.qcow2 is missing from the app bundle") }
        let tmp = docs.appendingPathComponent("debian-disk.copying")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try fm.moveItem(at: tmp, to: diskURL)
        var url = diskURL
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
    }

    // MARK: Boot

    func start(memoryMB: Int, cpus: Int, extraArgs: String) {
        guard !launchAttempted, state != .preparing else { return }
        launchAttempted = true
        state = .preparing
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.prepareDisk()
                try self.setupConsole()
                let args = try self.buildArgs(memoryMB: memoryMB, cpus: cpus, extraArgs: extraArgs)
                try self.launch(args)

            } catch {
                self.outputHandle?.readabilityHandler = nil
                if self.guestInput >= 0 { close(self.guestInput); self.guestInput = -1 }
                if self.serialGuestFD >= 0 { close(self.serialGuestFD); self.serialGuestFD = -1 }
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription + " Fully close and reopen the app before retrying.") }
            }
        }
    }

    private func buildArgs(memoryMB: Int, cpus: Int, extraArgs: String) throws -> [String] {
        guard (512...2048).contains(memoryMB), (1...4).contains(cpus) else {
            throw err("Use 512–2048 MB RAM and 1–4 CPUs")
        }
        // Do not allow a second accelerator, paused startup, or a redirected console
        // to silently invalidate the prepared JIT region and boot diagnostics.
        guard extraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw err("Clear Extra QEMU arguments for this verified boot configuration")
        }
        let fm = FileManager.default
        let kernel = vmBundleDir.appendingPathComponent("Image").path
        let initrd = vmBundleDir.appendingPathComponent("initrd").path
        guard fm.fileExists(atPath: kernel), fm.fileExists(atPath: initrd) else {
            throw err("Kernel or initrd missing from the app bundle")
        }
        let share = Bundle.main.bundleURL.appendingPathComponent("qemu").path
        let a = [
            "qemu-system-aarch64",
            "-L", share,
            "-nodefaults", "-no-user-config",
            "-machine", "virt",
            "-cpu", "cortex-a72",
            "-smp", "\(cpus)",
            "-m", "\(memoryMB)",
            // tb-size caps the JIT code cache (default would be 1 GB of extra RAM)
            "-accel", JITRegion.shared.isReady
                ? "tcg,thread=single,split-wx=on,tb-size=\(JITRegion.sizeMB)"
                : "tcg,thread=single,tb-size=128",
            "-kernel", kernel,
            "-initrd", initrd,
            "-append", "root=/dev/vda1 rw rootwait net.ifnames=0 earlycon=pl011,mmio32,0x09000000 console=ttyAMA0,115200 loglevel=7 ignore_loglevel systemd.show_status=1 systemd.firstboot=off",
            "-drive", "if=none,id=hd0,file=\(diskURL.path),format=qcow2,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=hd0",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-rng-pci",
            "-display", "none",
            "-monitor", "none",
            // Dedicated connected socket, also copied to serial.log for diagnosis
            "-chardev", "socket,id=con0,fd=\(serialGuestFD),server=off,logfile=\(serialLogURL.path)",
            "-serial", "chardev:con0",
            // Diagnostic: guest errors and unimplemented device accesses only (cheap)
            "-d", "guest_errors,unimp", "-D", cpuLogURL.path,
        ]
        return a
    }

    private func findQemu() -> String? {
        guard let fw = Bundle.main.privateFrameworksURL else { return nil }
        let candidates = [
            fw.appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu").path,
            fw.appendingPathComponent("libqemu-aarch64-softmmu.dylib").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LoopFn = @convention(c) () -> Int32
    private typealias CleanupFn = @convention(c) (Int32) -> Void

    private func launch(_ args: [String]) throws {
        guard JIT.isEnabled else { throw err("JIT is not enabled. Open the app from LiveContainer with JIT.") }
        guard let path = findQemu() else { throw err("QEMU framework not found in the app bundle") }
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST) else {
            throw err("dlopen failed: " + String(cString: dlerror()))
        }
        if JIT.needsScript {
            guard JITRegion.shared.isReady else {
                throw err("The JIT code region isn't ready. Launch with StikDebug's universal.js script (see the note under JIT).")
            }
            let patched = jit26_install_qemu_hooks("aarch64-softmmu")
            guard patched > 0 else { throw err("Could not redirect QEMU's JIT allocator (patched \(patched))") }
            emitNote("[Debian Pocket] JIT region \(JITRegion.sizeMB) MB ready, \(patched) QEMU imports redirected\n")
        }
        guard let pInit = dlsym(h, "qemu_init"),
              let pLoop = dlsym(h, "qemu_main_loop"),
              let pClean = dlsym(h, "qemu_cleanup") else {
            throw err("QEMU entry points not exported")
        }
        let qInit = unsafeBitCast(pInit, to: InitFn.self)
        let qLoop = unsafeBitCast(pLoop, to: LoopFn.self)
        let qClean = unsafeBitCast(pClean, to: CleanupFn.self)

        // Only stderr is mirrored; never replace LiveContainer's stdin/stdout.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logFD = open(logURL.path, O_WRONLY | O_TRUNC)
        guard logFD >= 0 else { throw err("Cannot open qemu.log") }
        guard dup2(logFD, STDERR_FILENO) >= 0 else { close(logFD); throw err("Cannot redirect QEMU errors") }
        close(logFD)

        // Leaked on purpose: QEMU keeps pointers into argv for its whole lifetime
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (i, s) in args.enumerated() { argv[i] = strdup(s) }
        argv[args.count] = nil
        let argc = Int32(args.count)

        let t = Thread {
            self.phase("inside qemu_init")
            qInit(argc, argv)
            if JIT.needsScript && jit26_handed() == 0 {
                self.emitNote("[Debian Pocket] ERROR: QEMU did not use the prepared JIT buffer. Close the app; do not continue.\n")
                DispatchQueue.main.async { self.state = .failed("JIT buffer was not used. Fully close the app.") }
                return
            }
            self.phase("QEMU initialized; waiting for Linux serial")
            let status = qLoop()
            qClean(status)
            exit(status)   // QEMU cannot be restarted in-process; guest poweroff closes the app
        }
        t.name = "qemu-main"
        t.stackSize = 8 << 20
        bootStart = Date()
        DispatchQueue.main.async { self.state = .booting }
        emitNote("[Debian Pocket] Build bootfix-5 / UTM 4.7.5 / QEMU 10.0.2\n[Debian Pocket] Starting QEMU: \(args.dropFirst().joined(separator: " "))\n\n")
        DispatchQueue.main.async { self.startLogMirror() }
        t.start()
    }

    private func phase(_ text: String) {
        DispatchQueue.main.async { self.bootPhase = text }
        emitNote("[Debian Pocket] " + text + "\n")
    }

    private func setupConsole() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw err("socketpair failed: " + String(cString: strerror(errno)))
        }
        serialGuestFD = fds[1] // QEMU owns this connected socket after qemu_init.
        guestInput = fds[0]
        var noSignal: Int32 = 1
        _ = setsockopt(guestInput, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        try? FileManager.default.removeItem(at: serialLogURL)
        try? FileManager.default.removeItem(at: cpuLogURL)
        let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.guestOutputSeen = true
                self.bootPhase = "Linux serial active"
                self.state = .running
                self.emit(Array(data))
            }
        }
        outputHandle = handle
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "DebianPocket", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

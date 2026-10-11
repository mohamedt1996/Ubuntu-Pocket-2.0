import Foundation
import Darwin

/// Boots Debian 13 (arm64) inside QEMU running in this same process.
/// The guest serial console is wired to stdin/stdout, which we redirect into pipes
/// that the terminal view reads from and writes to.
final class VMManager: ObservableObject {
    static let shared = VMManager()

    enum State: Equatable { case stopped, preparing, running, failed(String) }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lastLog: String?

    private var guestInput: Int32 = -1          // we write here -> guest serial RX
    private var outputHandle: FileHandle?       // guest serial TX -> we read here
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
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("ubuntu-disk.qcow2"))
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
    private var sawGuestOutput = false

    /// Copies new QEMU warnings/errors from qemu.log into the terminal in yellow,
    /// and prints a heartbeat until the guest says anything.
    private func startLogMirror() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
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
            // If Linux is writing to the serial log but nothing reached the terminal pipe,
            // show the log file instead so you can still read the boot.
            if !self.sawGuestOutput && serialSize > self.serialShown && secs >= 5,
               let h = try? FileHandle(forReadingFrom: self.serialLogURL) {
                h.seek(toFileOffset: self.serialShown)
                let d = h.readDataToEndOfFile(); try? h.close()
                self.serialShown += UInt64(d.count)
                let text = String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
                DispatchQueue.main.async { self.emit(Array(text.utf8)) }
            }
            if secs > 0 && secs % 10 == 0 && secs <= 300 && !self.sawGuestOutput {
                let handed = jit26_handed() != 0 ? "yes" : "NO"
                self.emitNote("[Debian Pocket] \(secs)s: serial.log \(self.human(serialSize)), cpu-trace \(self.human(self.fileSize(self.cpuLogURL))), code buffer used: \(handed)\n")
            }
        }
        t.resume()
        logTimer = t
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func human(_ n: UInt64) -> String {
        n < 1024 ? "\(n) B" : n < 1 << 20 ? "\(n >> 10) KB" : "\(n >> 20) MB"
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
        guard state != .preparing, state != .running else { return }
        state = .preparing
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.prepareDisk()
                let args = try self.buildArgs(memoryMB: memoryMB, cpus: cpus, extraArgs: extraArgs)
                try self.launch(args)
                DispatchQueue.main.async { self.state = .running }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func buildArgs(memoryMB: Int, cpus: Int, extraArgs: String) throws -> [String] {
        let fm = FileManager.default
        let kernel = vmBundleDir.appendingPathComponent("Image").path
        let initrd = vmBundleDir.appendingPathComponent("initrd").path
        guard fm.fileExists(atPath: kernel), fm.fileExists(atPath: initrd) else {
            throw err("Kernel or initrd missing from the app bundle")
        }
        let share = Bundle.main.bundleURL.appendingPathComponent("qemu").path
        var a = [
            "qemu-system-aarch64",
            "-L", share,
            "-machine", "virt",
            "-cpu", "cortex-a72",
            "-smp", "\(cpus)",
            "-m", "\(memoryMB)",
            // tb-size caps the JIT code cache (default would be 1 GB of extra RAM)
            "-accel", JITRegion.shared.isReady
                ? "tcg,thread=multi,split-wx=on,tb-size=\(JITRegion.sizeMB)"
                : "tcg,thread=multi,tb-size=256",
            "-kernel", kernel,
            "-initrd", initrd,
            "-append", "root=/dev/vda1 rw rootwait net.ifnames=0 earlycon=pl011,0x9000000 console=ttyAMA0 systemd.show_status=1",
            "-drive", "if=none,id=hd0,file=\(diskURL.path),format=qcow2,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=hd0",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-rng-pci",
            "-display", "none",
            "-monitor", "none",
            // Serial console on stdin/stdout, also copied to serial.log for diagnosis
            "-chardev", "stdio,id=con0,signal=off,logfile=\(serialLogURL.path)",
            "-serial", "chardev:con0",
            // Diagnostic: QEMU logs every translated guest block here, so we can see the CPU run
            "-d", "in_asm,int,guest_errors", "-D", cpuLogURL.path,
        ]
        a += extraArgs.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
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

    private typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LoopFn = @convention(c) () -> Int32
    private typealias CleanupFn = @convention(c) (Int32) -> Void

    private func launch(_ args: [String]) throws {
        guard JIT.isEnabled else { throw err("JIT is not enabled. Open the app from LiveContainer with JIT.") }
        guard let path = findQemu() else { throw err("QEMU framework not found in the app bundle") }
        guard let h = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            throw err("dlopen failed: " + String(cString: dlerror()))
        }
        if JIT.needsScript {
            guard JITRegion.shared.isReady else {
                throw err("The JIT code region isn't ready. Launch with StikDebug's universal.js script (see the note under JIT).")
            }
            let patched = jit26_install_qemu_hooks("aarch64-softmmu")
            guard patched >= 2 else { throw err("Could not redirect QEMU's JIT allocator (patched \(patched))") }
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

        // Serial console pipes
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0 else { throw err("pipe() failed") }
        dup2(inP[0], STDIN_FILENO); close(inP[0])
        dup2(outP[1], STDOUT_FILENO); close(outP[1])
        guestInput = inP[1]
        setvbuf(stdout, nil, _IONBF, 0)

        // QEMU warnings/errors go to a log file so they survive a crash
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try? FileManager.default.removeItem(at: serialLogURL)
        try? FileManager.default.removeItem(at: cpuLogURL)
        let logFD = open(logURL.path, O_WRONLY | O_TRUNC)
        if logFD >= 0 { dup2(logFD, STDERR_FILENO); close(logFD) }

        let handle = FileHandle(fileDescriptor: outP[0], closeOnDealloc: false)
        handle.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let bytes = [UInt8](d)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sawGuestOutput = true
                self.emit(bytes)
            }
        }
        outputHandle = handle

        // Leaked on purpose: QEMU keeps pointers into argv for its whole lifetime
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (i, s) in args.enumerated() { argv[i] = strdup(s) }
        argv[args.count] = nil
        let argc = Int32(args.count)

        let t = Thread {
            qInit(argc, argv, environ)
            let status = qLoop()
            qClean(status)
            exit(status)   // QEMU cannot be restarted in-process; guest poweroff closes the app
        }
        t.name = "qemu-main"
        t.stackSize = 8 << 20
        bootStart = Date()
        emitNote("[Debian Pocket] Starting QEMU: \(args.dropFirst().joined(separator: " "))\n\n")
        startLogMirror()
        t.start()
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "DebianPocket", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

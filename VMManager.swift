import Foundation
import Darwin

/// Boots Ubuntu (arm64) inside QEMU running in this same process.
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
    private var diskURL: URL { docs.appendingPathComponent("ubuntu-disk.qcow2") }
    private var logURL: URL { docs.appendingPathComponent("qemu.log") }
    private var vmBundleDir: URL { Bundle.main.bundleURL.appendingPathComponent("VM") }

    private init() {
        lastLog = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(4000)) }
    }

    // MARK: Terminal plumbing

    func attach(_ sink: @escaping (ArraySlice<UInt8>) -> Void) {
        self.sink = sink
        if !pending.isEmpty { sink(pending[...]); pending.removeAll() }
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
        let tmp = docs.appendingPathComponent("ubuntu-disk.copying")
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
            "-accel", "tcg,thread=multi,tb-size=256",
            "-kernel", kernel,
            "-initrd", initrd,
            "-append", "root=LABEL=cloudimg-rootfs rw console=ttyAMA0 quiet systemd.show_status=1",
            "-drive", "if=none,id=hd0,file=\(diskURL.path),format=qcow2,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=hd0",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-rng-pci",
            "-display", "none",
            "-monitor", "none",
            "-serial", "stdio",
        ]
        a += extraArgs.split(separator: " ").map(String.init)
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
        let logFD = open(logURL.path, O_WRONLY | O_TRUNC)
        if logFD >= 0 { dup2(logFD, STDERR_FILENO); close(logFD) }

        let handle = FileHandle(fileDescriptor: outP[0], closeOnDealloc: false)
        handle.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let bytes = [UInt8](d)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let s = self.sink { s(bytes[...]) } else { self.pending += bytes }
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
        t.start()
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "UbuntuPocket", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

import Foundation
import Darwin

/// Dedicated control socket: never sends commands into a user's shell/program.
final class QMPChannel {
    private(set) var guestFD: Int32 = -1
    private var hostFD: Int32 = -1
    private var handle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "pocket.qmp")
    var onReady: (() -> Void)?
    var onShutdown: (() -> Void)?
    var onError: ((String) -> Void)?

    func openChannel() throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        hostFD = fds[0]; guestFD = fds[1]
        var yes: Int32 = 1
        setsockopt(hostFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let h = FileHandle(fileDescriptor: hostFD, closeOnDealloc: false)
        h.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.receive(data) }
        }
        handle = h
    }

    func execute(_ command: String) {
        queue.async { self.writeCommand(command) }
    }
    private func writeCommand(_ command: String) {
        guard hostFD >= 0,
              var data = try? JSONSerialization.data(withJSONObject: ["execute": command, "id": command]) else { return }
        data.append(10)
        data.withUnsafeBytes { b in
            var sent = 0
            while sent < b.count {
                let n = Darwin.write(hostFD, b.baseAddress! + sent, b.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                sent += n
            }
        }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 1_048_576 else { buffer.removeAll(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if obj["QMP"] != nil { writeCommand("qmp_capabilities") }
            if obj["id"] as? String == "qmp_capabilities", obj["return"] != nil {
                DispatchQueue.main.async { self.onReady?() }
            }
            if let error = obj["error"] as? [String: Any] {
                let message = error["desc"] as? String ?? "QEMU control command failed"
                DispatchQueue.main.async { self.onError?(message) }
            }
            if obj["event"] as? String == "SHUTDOWN",
               let details = obj["data"] as? [String: Any],
               details["guest"] as? Bool == true,
               details["reason"] as? String == "guest-shutdown" {
                DispatchQueue.main.async { self.onShutdown?() }
            }
        }
    }
}

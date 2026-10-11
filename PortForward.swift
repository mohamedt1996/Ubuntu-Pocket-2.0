import Foundation

struct PortForward: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var transport: String = "tcp"
    var hostPort: Int
    var guestPort: Int
    var enabled = true
    var https = false

    var url: URL? {
        guard transport == "tcp", enabled else { return nil }
        return URL(string: "\(https ? "https" : "http")://127.0.0.1:\(hostPort)")
    }

    static let defaults = [
        PortForward(name: "SSH", hostPort: 2222, guestPort: 22),
        PortForward(name: "Web server", hostPort: 8080, guestPort: 8080),
        PortForward(name: "Stremio", hostPort: 11470, guestPort: 11470)
    ]

    static func networkArgument(_ rules: [PortForward]) throws -> String {
        var ports = Set<String>()
        var result = "user,id=net0,ipv6=off"
        for r in rules where r.enabled {
            guard ["tcp", "udp"].contains(r.transport),
                  (1...65535).contains(r.hostPort), (1...65535).contains(r.guestPort) else {
                throw NSError(domain: "Ports", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use TCP or UDP and ports from 1 to 65535."])
            }
            guard ports.insert("\(r.transport):\(r.hostPort)").inserted else {
                throw NSError(domain: "Ports", code: 2, userInfo: [NSLocalizedDescriptionKey: "Duplicate \(r.transport.uppercased()) iPhone port \(r.hostPort)."])
            }
            result += ",hostfwd=\(r.transport):127.0.0.1:\(r.hostPort)-:\(r.guestPort)"
        }
        return result
    }
}

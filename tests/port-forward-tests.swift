import Foundation
func check(_ condition: Bool) { precondition(condition) }
let tcp = PortForward(name: "A", hostPort: 8080, guestPort: 80)
let udp = PortForward(name: "B", transport: "udp", hostPort: 8080, guestPort: 53)
let network = try PortForward.networkArgument([tcp, udp])
check(network.contains("tcp:127.0.0.1:8080-:80"))
check(network.contains("udp:127.0.0.1:8080-:53"))
check(!network.contains("0.0.0.0"))
for rules in [[tcp, tcp], [PortForward(name: "bad", hostPort: 0, guestPort: 80)],
              [PortForward(name: "bad", hostPort: 80, guestPort: 65536)],
              [PortForward(name: "bad", transport: "tcp,hostfwd=bad", hostPort: 80, guestPort: 80)]] {
    do { _ = try PortForward.networkArgument(rules); fatalError("Invalid mapping accepted") }
    catch {}
}
var disabled = tcp; disabled.enabled = false
check(try PortForward.networkArgument([tcp, disabled]) == PortForward.networkArgument([tcp]))
check(disabled.url == nil && udp.url == nil)
check(tcp.url?.absoluteString == "http://127.0.0.1:8080")
check(try JSONDecoder().decode([PortForward].self, from: JSONEncoder().encode([tcp, udp])) == [tcp, udp])
print("PASS: TCP/UDP, loopback binding, validation, duplicates, disabled rules, links, persistence")

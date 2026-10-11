import SwiftUI
import WebKit

final class PortStore: ObservableObject {
    static let shared = PortStore()
    @Published var rules: [PortForward] {
        didSet { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "portRules.v1") } }
    }
    init() {
        rules = UserDefaults.standard.data(forKey: "portRules.v1")
            .flatMap { try? JSONDecoder().decode([PortForward].self, from: $0) } ?? PortForward.defaults
    }
}

struct PortSettings: View {
    @ObservedObject var store = PortStore.shared
    @ObservedObject var vm = VMManager.shared
    @State private var name = ""
    @State private var host = ""
    @State private var guest = ""
    @State private var transport = "tcp"
    @State private var https = false
    @State private var error: String?
    var body: some View {
        Form {
            Section(footer: Text("Any Docker service can use these mappings. Publish its container port in Docker (for example -p 8080:80). Mappings apply on the next VM launch. Only this iPhone can connect; these ports are not exposed to your Wi-Fi network.")) {
                ForEach($store.rules) { $rule in
                    NavigationLink {
                        PortEditor(rule: $rule)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(rule.name + (rule.enabled ? "" : " (disabled)"))
                            Text("\(rule.transport.uppercased()) · iPhone \(rule.hostPort) → Debian \(rule.guestPort)").font(.caption)
                        }
                    }
                }.onDelete { store.rules.remove(atOffsets: $0) }
            }
            Section("Add forwarding") {
                TextField("Server name", text: $name)
                Picker("Protocol", selection: $transport) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }
                TextField("iPhone port", text: $host).keyboardType(.numberPad)
                TextField("Debian published port", text: $guest).keyboardType(.numberPad)
                if transport == "tcp" { Toggle("HTTPS server link", isOn: $https) }
                Button("Add mapping") {
                    guard let h = Int(host), let g = Int(guest) else { error = "Enter numeric ports."; return }
                    let rule = PortForward(name: name.isEmpty ? "Server \(h)" : name, transport: transport, hostPort: h, guestPort: g, https: https)
                    do {
                        _ = try PortForward.networkArgument(store.rules + [rule])
                        store.rules.append(rule); host = ""; guest = ""; name = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }
                if let error { Text(error).foregroundColor(.red) }
            }
            if !vm.activeForwards.isEmpty {
                Section("Active this session") {
                    ForEach(vm.activeForwards.filter(\.enabled)) { r in
                        Text("\(r.transport.uppercased()) \(r.hostPort) → \(r.guestPort)")
                    }
                }
            }
        }.navigationTitle("Port forwarding")
    }
}

struct ServerLinks: View {
    @ObservedObject var vm = VMManager.shared
    @State private var selected: URL?
    var body: some View {
        List {
            Section(footer: Text("These are active TCP mappings, not proof a web server is running. SSH and other non-web protocols cannot open in a browser.")) {
                ForEach(vm.activeForwards.filter { $0.enabled && $0.transport == "tcp" }) { rule in
                    Button { selected = rule.url } label: {
                        VStack(alignment: .leading) {
                            Text(rule.name)
                            Text(rule.url?.absoluteString ?? "").font(.caption)
                        }
                    }
                }
            }
        }.navigationTitle("Servers")
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { BrowserPanel(url: selected) }
        }
    }
}

struct BrowserPanel: View {
    let url: URL
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            ServerWebView(url: url).navigationTitle(url.host ?? "Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }
}
struct ServerWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(); view.load(URLRequest(url: url)); return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PortEditor: View {
    @Binding var rule: PortForward
    @State private var draft: PortForward
    @State private var host: String
    @State private var guest: String
    @State private var error: String?
    @Environment(\.dismiss) var dismiss
    init(rule: Binding<PortForward>) {
        _rule = rule; _draft = State(initialValue: rule.wrappedValue)
        _host = State(initialValue: String(rule.wrappedValue.hostPort))
        _guest = State(initialValue: String(rule.wrappedValue.guestPort))
    }
    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            Toggle("Enabled", isOn: $draft.enabled)
            Picker("Protocol", selection: $draft.transport) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }
            TextField("iPhone port", text: $host).keyboardType(.numberPad)
            TextField("Debian published port", text: $guest).keyboardType(.numberPad)
            Toggle("HTTPS link", isOn: $draft.https)
            Text("Changes take effect on the next VM launch.").font(.caption)
            if let error { Text(error).foregroundColor(.red) }
            Button("Save") {
                guard let h = Int(host), let g = Int(guest), (1...65535).contains(h), (1...65535).contains(g) else {
                    error = "Use ports from 1 to 65535."; return
                }
                draft.hostPort = h; draft.guestPort = g
                do {
                    _ = try PortForward.networkArgument(PortStore.shared.rules.map { $0.id == draft.id ? draft : $0 })
                    rule = draft; dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }.navigationTitle("Edit forwarding")
    }
}

import SwiftUI

@main
struct UbuntuPocketApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @ObservedObject private var vm = VMManager.shared
    @AppStorage("ramMB") private var ramMB: Int = 2048
    @AppStorage("cpus") private var cpus: Int = 4
    @AppStorage("extraArgs") private var extraArgs: String = ""
    @State private var confirmReset = false

    var body: some View {
        switch vm.state {
        case .running:
            TerminalScreen()
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color.black)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        default:
            settings
        }
    }

    private var settings: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("JIT")
                        Spacer()
                        Text(JIT.isEnabled ? "Enabled" : "Not detected")
                            .foregroundColor(JIT.isEnabled ? .green : .orange)
                    }
                    if !JIT.isEnabled {
                        Text("Without JIT the VM will not start. Launch this app from LiveContainer with JIT enabled.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                Section(header: Text("Virtual machine")) {
                    Stepper("Memory: \(ramMB) MB", value: $ramMB, in: 1024...3072, step: 256)
                    if ramMB > 2560 {
                        Text("Above 2.5 GB iOS is likely to close the app once the VM fills its memory (for example during docker pull).")
                            .font(.footnote).foregroundColor(.orange)
                    }
                    Stepper("CPU cores: \(cpus)", value: $cpus, in: 1...6)
                    TextField("Extra QEMU arguments (optional)", text: $extraArgs)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                Section {
                    Button(action: { vm.start(memoryMB: ramMB, cpus: cpus, extraArgs: extraArgs) }) {
                        HStack {
                            Text(vm.state == .preparing ? "Preparing disk…" : "Start Ubuntu")
                            if vm.state == .preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(vm.state == .preparing)
                    if case .failed(let msg) = vm.state {
                        Text(msg).font(.footnote).foregroundColor(.red)
                    }
                }
                if let log = vm.lastLog, !log.isEmpty {
                    Section(header: Text("Last QEMU log")) {
                        Text(log).font(.system(.caption, design: .monospaced))
                    }
                }
                Section {
                    Button("Reset Ubuntu disk", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Ubuntu Pocket")
            .alert("Erase the Ubuntu disk?", isPresented: $confirmReset) {
                Button("Erase", role: .destructive) { vm.resetDisk() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything inside the VM, including Docker images, is deleted.")
            }
        }
        .navigationViewStyle(.stack)
    }
}

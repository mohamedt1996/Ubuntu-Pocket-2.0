import SwiftUI

@main
struct UbuntuPocketApp: App {
    init() { JITRegion.shared.prepareAtLaunch() }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @ObservedObject private var vm = VMManager.shared
    @ObservedObject private var jit = JITRegion.shared
    @AppStorage("vmRamMB") private var ramMB: Int = 1024
    @AppStorage("vmCpus") private var cpus: Int = 1
    @AppStorage("extraArgs") private var extraArgs: String = ""
    @State private var confirmReset = false

    var body: some View {
        switch vm.state {
        case .booting, .running:
            TerminalScreen()
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color.black)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        default:
            settings
        }
    }

    private var regionText: String {
        switch jit.status {
        case .waiting: return "Waiting…"
        case .ready: return "Ready (\(JITRegion.sizeMB) MB)"
        case .notNeeded: return "Not needed"
        case .noDebugger: return "No debugger"
        case .crashedLastTime: return "Script missing"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var jitHelp: String {
        switch jit.status {
        case .ready, .notNeeded: return ""
        case .failed: return "JIT preparation failed before QEMU started. Fully close LiveContainer before retrying; do not reset the Debian disk."
        case .crashedLastTime:
            return "The last launch closed because no universal.js script answered. In StikDebug, set the script for LiveContainer to universal.js, then relaunch with JIT."
        default:
            return "iOS 26+ needs StikDebug's universal.js script. In LiveContainer settings turn on \"Use LiveContainer's Bundle ID\", in StikDebug pick universal.js for LiveContainer, then launch this app with JIT."
        }
    }

    private var settings: some View {
        NavigationView {
            Form {
                Section { Text("bootfix-5 · UTM 4.7.5").font(.caption) }
                Section(footer: Text(jitHelp).font(.footnote)) {
                    HStack {
                        Text("JIT")
                        Spacer()
                        Text(JIT.isEnabled ? "Enabled" : "Not detected")
                            .foregroundColor(JIT.isEnabled ? .green : .orange)
                    }
                    if JIT.needsScript {
                        HStack {
                            Text("Code region")
                            Spacer()
                            Text(regionText).foregroundColor(jit.status == .ready ? .green : .orange)
                        }
                    }
                }
                Section(header: Text("Virtual machine")) {
                    Stepper("Memory: \(ramMB) MB", value: $ramMB, in: 512...2048, step: 256)
                    if ramMB > 2560 {
                        Text("Above 2.5 GB iOS is likely to close the app once the VM fills its memory (for example during docker pull).")
                            .font(.footnote).foregroundColor(.orange)
                    }
                    Stepper("CPU cores: \(cpus)", value: $cpus, in: 1...4)
                    Text("Debian 13 \"trixie\" · login root / debian · First boot: 1 GB and 1 core; clear extra arguments")
                        .font(.footnote).foregroundColor(.secondary)
                    TextField("Extra QEMU arguments (optional)", text: $extraArgs)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                Section {
                    Button(action: { vm.start(memoryMB: ramMB, cpus: cpus, extraArgs: extraArgs) }) {
                        HStack {
                            Text(vm.state == .preparing ? "Preparing disk…" : "Start Debian")
                            if vm.state == .preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(vm.state == .preparing || (JIT.needsScript && jit.status != .ready))
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
                    Button("Reset Debian disk", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Debian Pocket")
            .alert("Erase the Debian disk?", isPresented: $confirmReset) {
                Button("Erase", role: .destructive) { vm.resetDisk() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything inside the VM, including Docker images, is deleted.")
            }
        }
        .navigationViewStyle(.stack)
    }
}

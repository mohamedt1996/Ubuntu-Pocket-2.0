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
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("keepAwake") private var keepAwake = true
    @State private var showTools = false
    @State private var showHistory = false
    @State private var showPiP = false
    @State private var confirmShutdown = false
    @State private var queuedCommand: String?
    @State private var pastedText: String?
    @ObservedObject private var pip = TerminalPiP.shared
    @State private var confirmReset = false
    @State private var confirmGuestTools = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var background = BackgroundExecution.shared

    var body: some View {
        Group {
            switch vm.state {
            case .booting, .running, .shuttingDown:
                console
            case .poweredOff:
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundColor(.green)
                    Text("Debian shut down safely").font(.title2)
                    Text(vm.controlMessage).multilineTextAlignment(.center)
                }.padding().onAppear { UIApplication.shared.isIdleTimerDisabled = false }
            default: settings
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background && (vm.state == .running || vm.state == .booting || vm.state == .shuttingDown) { background.leaveForeground() }
            else if phase == .active { background.enterForeground() }
        }
    }

    private var console: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pip.active ? "PiP active" : background.status).font(.caption2).lineLimit(1)
                Spacer()
                Button("Tools") { showTools = true }
                Button { confirmShutdown = true } label: { Image(systemName: "power") }
                    .disabled(!vm.controlReady || vm.state == .shuttingDown)
            }.padding(8)
            if !vm.controlMessage.isEmpty { Text(vm.controlMessage).font(.caption).foregroundColor(.orange).padding(6) }
            TerminalScreen(fontSize: fontSize)
            if showPiP {
                HStack {
                    PiPPreview().frame(width: 160, height: 90)
                    VStack {
                        Text(pip.status).font(.caption2)
                        Button("Start PiP") { pip.start() }.disabled(!pip.possible)
                        Button("Close preview") { pip.stop(); showPiP = false }
                    }
                }.padding(4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Button("Ctrl+C") { TerminalSession.shared.key("\u{03}") }
                    Button("Esc") { TerminalSession.shared.key("\u{1b}") }
                    Button("Tab") { TerminalSession.shared.key("\t") }
                    Button("↑") { TerminalSession.shared.key("\u{1b}[A") }
                    Button("↓") { TerminalSession.shared.key("\u{1b}[B") }
                    Button("Copy") { TerminalSession.shared.view.copy(nil) }
                    Button("Paste") { pastedText = UIPasteboard.general.string }
                    Button("Search") { showHistory = true }
                    Button("A−") { fontSize = max(9, fontSize - 1) }
                    Button("A+") { fontSize = min(26, fontSize + 1) }
                    Button("Keyboard") {
                        let v = TerminalSession.shared.view
                        if v.isFirstResponder { v.resignFirstResponder() } else { v.becomeFirstResponder() }
                    }
                }.padding(10)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            pip.restore = { showTools = false; showHistory = false }
        }
        .onChange(of: keepAwake) { UIApplication.shared.isIdleTimerDisabled = $0 }
        .sheet(isPresented: $showHistory) { ConsoleHistory() }
        .sheet(isPresented: $showTools) { toolsPanel }
        .alert("Shut down Debian safely?", isPresented: $confirmShutdown) {
            Button("Shut down", role: .destructive) { vm.requestShutdown() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Stops containers and services. Keep the app open until disk cleanup is confirmed. It will not force-stop the VM.") }
        .alert("Paste into terminal?", isPresented: Binding(get: { pastedText != nil }, set: { if !$0 { pastedText = nil } })) {
            Button("Paste") { if let text = pastedText { TerminalSession.shared.key(text) }; pastedText = nil }
            Button("Cancel", role: .cancel) { pastedText = nil }
        } message: { Text("Pasted newlines can execute commands.\n" + String((pastedText ?? "").prefix(500))) }
        .alert("Run at an idle root prompt?", isPresented: Binding(get: { queuedCommand != nil }, set: { if !$0 { queuedCommand = nil } })) {
            Button("Run") { if let command = queuedCommand { vm.runGuestCommand(command) }; queuedCommand = nil }
            Button("Cancel", role: .cancel) { queuedCommand = nil }
        } message: { Text("First stop any foreground command and return to a root shell.\n" + (queuedCommand ?? "")) }
        .alert("Install guest tools?", isPresented: $confirmGuestTools) {
            Button("Install") { vm.installGuestTools() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Return to an idle root prompt first. Applies permanent DNS, clock and console fixes to your existing disk without resetting it.") }
    }

    private var toolsPanel: some View {
        NavigationView {
            List {
                Section("Servers") {
                    NavigationLink("Port forwarding") { PortSettings() }
                    NavigationLink("Open server") { ServerLinks() }
                    Button("Guest network diagnostics") { queue("pocket-net; printf '\\nListening ports:\\n'; ss -lntup; docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'") }
                }
                Section("Terminal") {
                    Button("Console search and export") { showTools = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showHistory = true } }
                    Button("Start / resume tmux session") { queue("command -v tmux >/dev/null && tmux new-session -A -s pocket || echo 'Install tmux with: apt install tmux'") }
                    Button("New tmux window") { showTools = false; TerminalSession.shared.key("\u{02}c") }
                    Button("Next tmux window") { showTools = false; TerminalSession.shared.key("\u{02}n") }
                    Button("Sync shell terminal size") { queue("stty cols \(TerminalSession.shared.columns) rows \(TerminalSession.shared.rows)") }
                    Text("Window buttons require an active tmux session. Sessions survive UI navigation and background suspension, not VM shutdown.").font(.caption)
                }
                Section("Background") {
                    Toggle("Keep screen awake while Debian is open", isOn: $keepAwake)
                    Button("Show experimental terminal PiP") {
                        showTools = false; showPiP = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pip.beginPreview() }
                    }
                    Text("PiP is a read-only video preview. Use its return button to reopen the terminal. iOS and LiveContainer may refuse or stop it; continuous background execution is not guaranteed.").font(.caption)
                }
                Section("Maintenance") {
                    Button("Install / update guest tools") { showTools = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmGuestTools = true } }
                    Text("Existing disks keep their packages and files. Install tmux once with apt install tmux if using an older disk.").font(.caption)
                }
            }.navigationTitle("Debian tools")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTools = false } } }
        }.navigationViewStyle(.stack)
    }
    private func queue(_ command: String) {
        showTools = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { queuedCommand = command }
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
                Section { Text("server-tools-1 · UTM 4.7.5").font(.caption) }
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
                Section { NavigationLink("Port forwarding") { PortSettings() } }
                Section {
                    Button(action: { vm.start(memoryMB: ramMB, cpus: cpus, extraArgs: extraArgs) }) {
                        HStack {
                            Text(vm.state == .preparing ? "Preparing disk…" : "Start Debian")
                            if vm.state == .preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(vm.launchAttempted || vm.state == .preparing || (JIT.needsScript && jit.status != .ready))
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
                    Button("Reset Debian disk", role: .destructive) { confirmReset = true }.disabled(vm.launchAttempted)
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

import SwiftUI
import UIKit
import SwiftTerm

/// Keep one terminal alive when opening settings, the browser, or PiP.
final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    static let shared = TerminalSession()
    let view = TerminalView(frame: .zero)
    override init() {
        super.init()
        view.terminalDelegate = self
        VMManager.shared.attach { [weak self] bytes in self?.view.feed(byteArray: bytes) }
        TerminalPiP.shared.configure { [weak self] in
            guard let view = self?.view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
                view.layer.render(in: context.cgContext)
            }
        }
    }
    func key(_ text: String) { VMManager.shared.send(Array(text.utf8)[...]) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { VMManager.shared.send(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Raw serial has no SSH/PTTY window channel. User-triggered size sync is in the toolbar.
        columns = newCols; rows = newRows
    }
    var columns = 80
    var rows = 24
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalScreen: UIViewRepresentable {
    var fontSize: Double
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalSession.shared.view
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ uiView: TerminalView, context: Context) {
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if uiView.font != font { uiView.font = font }
    }
}

struct ConsoleHistory: View {
    @ObservedObject var vm = VMManager.shared
    @State private var query = ""
    @Environment(\.dismiss) var dismiss
    private var cleaned: String {
        vm.transcript.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
    private var lines: String {
        guard !query.isEmpty else { return cleaned }
        return cleaned.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }
    var body: some View {
        NavigationView {
            ScrollView {
                Text(lines).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .searchable(text: $query, prompt: "Search recent console output")
            .navigationTitle("Console history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { ShareLink(item: lines) { Image(systemName: "square.and.arrow.up") } }
            }
        }.navigationViewStyle(.stack)
    }
}

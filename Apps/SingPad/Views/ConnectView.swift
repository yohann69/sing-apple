import SingClient
import SingCore
import SingDesign
import SwiftUI
import VisionKit

struct ConnectView: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme
    @State private var selected: ServerEndpoint?
    @State private var manualHost = ""
    @State private var scanning = false

    var body: some View {
        ZStack {
            BlobBackground(colors: theme.blobs, base: theme.background, period: 30, dim: 0.35)
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Text("Sing!")
                            .font(.system(size: 72, weight: .black, design: .rounded))
                            .foregroundStyle(LinearGradient(colors: [theme.accentSoft, theme.accent], startPoint: .top, endPoint: .bottom))
                        Text("Join the karaoke Mac on this Wi‑Fi").font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.top, 60)

                    GlassEffectContainer(spacing: 14) {
                        VStack(spacing: 14) {
                            if model.discovered.isEmpty {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("Looking for Sing! Macs…")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(22)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                            }
                            ForEach(model.discovered) { ep in
                                Button { selected = ep } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "macmini.fill").font(.title2)
                                        VStack(alignment: .leading) {
                                            Text(ep.name).font(.headline)
                                            Text("\(ep.host)").font(.caption).opacity(0.7)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                    .padding(20)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26))
                            }
                        }
                    }
                    .frame(maxWidth: 520)

                    HStack(spacing: 12) {
                        if DataScannerViewController.isSupported {
                            Button { scanning = true } label: {
                                Label("Scan the TV code", systemImage: "qrcode.viewfinder").padding(.vertical, 6)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or type the Mac's address").font(.subheadline.weight(.semibold)).opacity(0.85)
                        HStack {
                            TextField("192.168.1.20", text: $manualHost)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .padding(12)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                            Button("Next") {
                                let parts = manualHost.split(separator: ":")
                                let host = String(parts.first ?? "")
                                let port = parts.count > 1 ? Int(parts[1]) ?? SingProtocol.defaultPort : SingProtocol.defaultPort
                                selected = ServerEndpoint(name: host, host: host, port: port)
                            }
                            .buttonStyle(.glass)
                            .disabled(manualHost.isEmpty)
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .padding(24)
                .foregroundStyle(.white)
            }
        }
        .onAppear { model.startBrowsing() }
        .onDisappear { model.stopBrowsing() }
        .sheet(item: $selected) { ep in CodeEntrySheet(endpoint: ep) }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerView { url in
                scanning = false
                model.handleJoinURL(url)
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button { scanning = false } label: { Image(systemName: "xmark").padding(10) }.accessibilityLabel("Close")
                    .buttonStyle(.glass)
                    .padding()
            }
        }
    }
}

struct CodeEntrySheet: View {
    var endpoint: ServerEndpoint
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Text("Enter the code").font(.title.bold())
            Text("Guests: the code on the TV. Hosts: the code in the Mac's Pads screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("000000", text: $code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .focused($focused)
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                .onChange(of: code) { _, v in
                    code = String(v.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }
            if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button {
                submit()
            } label: {
                if busy { ProgressView() } else { Text("Join \(endpoint.name)").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(code.count != 6 || busy)
        }
        .padding(28)
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await model.pair(endpoint, code: code)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                code = ""
            }
            busy = false
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onURL: (URL) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .fast, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onURL: onURL) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onURL: (URL) -> Void
        var done = false
        init(onURL: @escaping (URL) -> Void) { self.onURL = onURL }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue, let url = URL(string: s), ServerEndpoint.parse(joinURL: url) != nil, !done {
                    done = true
                    onURL(url)
                }
            }
        }
    }
}

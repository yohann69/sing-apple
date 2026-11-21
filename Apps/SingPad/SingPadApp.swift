import SingCore
import SingDesign
import SwiftUI

@main
struct SingPadApp: App {
    @State private var model = PadModel()

    var body: some Scene {
        WindowGroup {
            PadRoot()
                .environment(model)
                .environment(\.singTheme, SingTheme(id: model.state.settings.theme.preset))
                .preferredColorScheme(SingTheme(id: model.state.settings.theme.preset).colorScheme)
                .tint(SingTheme(id: model.state.settings.theme.preset).accent)
                .onOpenURL { model.handleJoinURL($0) }
        }
    }
}

struct PadRoot: View {
    @Environment(PadModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.saved == nil {
                ConnectView()
                    .transition(.blurReplace)
            } else if UIDevice.current.userInterfaceIdiom == .pad {
                PadDashboard()
                    .transition(.blurReplace)
            } else {
                MainTabs()
                    .transition(.blurReplace)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: model.saved == nil)
        .overlay(alignment: .top) { ToastView() }
        .task {
            if model.saved != nil { model.connect() }
        }
        .onChange(of: phase) { _, p in
            if p == .active, model.saved != nil, model.connection != .connected { model.connect() }
        }
    }
}

struct ToastView: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { model.toast = nil }
                }
        }
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            Group {
                if let pane = model.pane {
                    switch pane {
                    case .quickShare: WirelessView(tab: .quickShare)
                    case .wifi: WirelessView(tab: .wifi)
                    case .transfers: TransfersView()
                    case .guide: GuideView()
                    }
                } else if model.connection == .ready {
                    BrowserView()
                } else {
                    OnboardingView()
                }
            }
            .overlay(alignment: .bottom) { ToastView() }
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.toast {
            HStack(spacing: 8) {
                Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? .orange : .green)
                Text(t.message).lineLimit(2)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
            .onTapGesture { model.toast = nil }
        }
    }
}

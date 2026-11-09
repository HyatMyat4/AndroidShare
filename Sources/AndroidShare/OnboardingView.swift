import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: model.connection != .noADB)
                    .padding(.top, 30)

                Text(headline).font(.title.bold())
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                switch model.connection {
                case .noADB: installADB
                case .unauthorized: unauthorizedSteps
                case .starting: ProgressView()
                default: connectSteps
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Android Share")
    }

    private var icon: String {
        switch model.connection {
        case .noADB: return "wrench.and.screwdriver"
        case .unauthorized: return "hand.tap"
        default: return "cable.connector"
        }
    }

    private var headline: String {
        switch model.connection {
        case .noADB: return "One-time setup"
        case .unauthorized: return "Tap “Allow” on your phone"
        case .offline: return "Phone is offline"
        case .starting: return "Starting…"
        default: return "Connect your Android phone"
        }
    }

    private var subtitle: String {
        switch model.connection {
        case .noADB: return "Android Share uses Google's free Android Platform Tools to talk to your phone. Install it once and you're done."
        case .unauthorized: return "Your phone is asking whether to trust this Mac. Unlock it and tap Allow."
        case .offline: return "Unplug the cable and plug it back in. Keep the phone unlocked."
        default: return "Plug your phone in with a USB cable. It will show up here automatically."
        }
    }

    private var installADB: some View {
        StepCard {
            Text("Open Terminal and run:").font(.headline)
            HStack {
                Text("brew install --cask android-platform-tools")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install --cask android-platform-tools", forType: .string)
                    copied = true
                }
            }
            Text("Android Share will detect it automatically. If adb is installed somewhere unusual, set its path in Settings (⌘,).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var unauthorizedSteps: some View {
        StepCard {
            StepRow(n: 1, text: "Unlock your phone.")
            StepRow(n: 2, text: "Look for the popup “Allow USB debugging?”")
            StepRow(n: 3, text: "Tick “Always allow from this computer”, then tap **Allow**.")
            Text("Don't see the popup? Unplug and replug the cable.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var connectSteps: some View {
        VStack(spacing: 16) {
            StepCard {
                Text("First time? Turn on USB debugging (once):").font(.headline)
                StepRow(n: 1, text: "On the phone open **Settings → About phone**.")
                StepRow(n: 2, text: "Tap **Build number** 7 times (on Xiaomi: *MIUI/OS version*; on Samsung: *Software information → Build number*).")
                StepRow(n: 3, text: "Go back to **Settings → System → Developer options**.")
                StepRow(n: 4, text: "Turn on **USB debugging**.")
                StepRow(n: 5, text: "Plug in the cable and tap **Allow** on the phone.")
            }
            Label("Waiting for a phone…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            Button {
                model.pane = .wifi
            } label: {
                Label("No cable? Use Quick Share or Wi-Fi Transfer instead", systemImage: "wifi")
            }
            .buttonStyle(.link)
        }
    }
}

struct StepCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StepRow: View {
    let n: Int
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }
}

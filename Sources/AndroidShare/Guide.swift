import SwiftUI

/// "Which way should I use?" Helps people pick Quick Share / Wi-Fi for light transfers
/// and the USB cable for big ones (long videos, 2 GB, 20 GB…).
struct TransferGuide: View {
    @EnvironmentObject var model: AppModel
    var highlight: AppModel.Pane? = nil   // which method the current page is about
    var collapsible = true
    @AppStorage("guideExpanded") private var storedExpanded = true
    private var expanded: Bool { !collapsible || storedExpanded }

    private struct Method: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let bestFor: String
        let speed: String
        let pane: AppModel.Pane?
    }

    private let methods = [
        Method(id: "qs", symbol: "square.and.arrow.down.on.square", title: "Quick Share",
               bestFor: "A few photos, screenshots, documents and links. Fastest to start, since it's already in the phone's Share menu.",
               speed: "Wi-Fi speed · best under 1 GB", pane: .quickShare),
        Method(id: "wifi", symbol: "wifi", title: "Wi-Fi Transfer",
               bestFor: "Photos and files from any phone, including Xiaomi, Huawei, OPPO and vivo. Also sends files from the Mac to the phone.",
               speed: "Wi-Fi speed · best under 1 GB", pane: .wifi),
        Method(id: "usb", symbol: "cable.connector", title: "USB Cable",
               bestFor: "Big files: long videos, 2 GB, 20 GB and more, whole folders, backups. Most reliable, and it doesn't drop if the phone sleeps.",
               speed: "Fastest · any size", pane: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if collapsible { Button {
                withAnimation(.easeInOut(duration: 0.2)) { storedExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text("Which one should I use?").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain) }

            if expanded {
                Text("**Light transfers → wireless. Heavy transfers → USB cable.** Wi-Fi is handy for everyday photos. For long videos and anything over about 1 GB, a cable is usually 3–10× faster.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(methods) { m in methodCard(m) }
                }

                timeTable

                Text("Times are typical. Wi-Fi depends on your router and distance. USB depends on the cable: many phone cables are USB 2, and a USB 3 / USB-C data cable is much faster.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func methodCard(_ m: Method) -> some View {
        let isHere = collapsible && highlight == m.pane && (m.pane != nil || highlight == nil)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: m.symbol).foregroundStyle(Color.accentColor)
                Text(m.title).font(.subheadline.bold())
            }
            Text(m.speed).font(.caption.weight(.semibold))
                .foregroundStyle(m.pane == nil ? Color.green : Color.secondary)
            Text(m.bestFor).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !isHere {
                Button(m.pane == nil ? "Use USB" : "Open") { model.pane = m.pane }
                    .controlSize(.small)
            } else {
                Text("You're here").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isHere ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isHere ? 1.5 : 1))
    }

    /// Rough times at typical speeds: Wi-Fi ≈ 15 MB/s, USB 2 ≈ 35 MB/s, USB 3 ≈ 150 MB/s.
    private var timeTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("About how long").font(.caption.bold())
                Text("100 MB").font(.caption.bold())
                Text("2 GB").font(.caption.bold())
                Text("20 GB").font(.caption.bold())
            }
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Quick Share / Wi-Fi", "7 sec", "2 min", "25 min", good: false)
            row("USB cable", "3 sec", "1 min", "10 min", good: true)
            row("USB 3 / USB-C data cable", "1 sec", "15 sec", "2–3 min", good: true)
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
    }

    private func row(_ name: String, _ a: String, _ b: String, _ c: String, good: Bool) -> some View {
        GridRow {
            Text(name)
            Text(a).monospacedDigit()
            Text(b).monospacedDigit()
            Text(c).monospacedDigit().foregroundStyle(good ? Color.green : Color.orange).fontWeight(.medium)
        }
    }
}

/// Sidebar tab: when to use Quick Share, Wi-Fi Transfer or the USB cable.
struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 28)).foregroundStyle(.yellow)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Which one should I use?").font(.title.bold())
                        Text("Android Share can move files three ways. Pick by size: wireless for everyday photos, the cable for big files.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                TransferGuide(collapsible: false)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("User Guide")
    }
}

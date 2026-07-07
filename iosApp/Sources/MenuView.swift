import SwiftUI

/// The Chika menu / about screen — the SwiftUI port of Android's MenuScreen.kt. Holds the AMOLED
/// theme toggle and the about/support section, over the ink ground with a faint crimson halftone.
struct MenuView: View {
    @EnvironmentObject private var settings: ChikaSettings
    @Environment(\.dismiss) private var dismiss

    /// Points at the project repository (was the maintainer's personal GitHub Pages site).
    private static let repoURL = URL(string: "https://github.com/batunii/chika")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ZStack {
            settings.ground.ignoresSafeArea()
            Halftone(color: Chika.crimson, alpha: 0.05).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header: back + title.
                    HStack(spacing: 14) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Chika.cream)
                                .frame(width: 38, height: 38)
                                .background(Chika.cream.opacity(0.12))
                                .clipShape(Circle())
                        }
                        OchreBadge(text: "Menu")
                        Spacer()
                    }
                    .padding(.top, 8)

                    Spacer().frame(height: 28)

                    // ---- Theme -------------------------------------------------------
                    SectionLabel("THEME")
                    Spacer().frame(height: 10)
                    ToggleRow(
                        title: "AMOLED Black",
                        subtitle: "True-black background — easy on OLED screens and battery.",
                        isOn: $settings.amoled
                    )

                    Spacer().frame(height: 32)

                    // ---- About -------------------------------------------------------
                    SectionLabel("ABOUT")
                    Spacer().frame(height: 16)
                    ChikaWordmark()
                    Spacer().frame(height: 12)
                    OchreBadge(text: "Version \(version)")
                    Spacer().frame(height: 14)
                    Text("Made with ❤️ by Chakra")
                        .font(.archivo(14)).foregroundColor(Chika.cream)
                    Spacer().frame(height: 18)
                    Text("Chika is a comic reader that detects panels on-device and guides you "
                         + "through each page, panel by panel.")
                        .font(.archivo(13)).lineSpacing(4).foregroundColor(Chika.cream)

                    Spacer().frame(height: 28)

                    // ---- Support -----------------------------------------------------
                    Text("Chika is free and made with care. If it brings you joy, you can support "
                         + "its making.")
                        .font(.archivo(12)).lineSpacing(3).foregroundColor(Chika.creamMuted)
                    Spacer().frame(height: 14)
                    Link(destination: Self.repoURL) {
                        HStack(spacing: 10) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 16)).foregroundColor(Chika.cream)
                            Text("SUPPORT / DONATE")
                                .font(.anton(15)).tracking(0.5).foregroundColor(Chika.cream)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Chika.crimson)
                        .clipShape(RoundedCornerShape(cornerRadius: 4))
                        .comicShadow(offset: 4, color: .black.opacity(0.6), corner: 4)
                    }
                    Spacer().frame(height: 6)
                    Link(destination: Self.repoURL) {
                        Text("github.com/batunii/chika")
                            .font(.archivo(11)).foregroundColor(Chika.ochre)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .navigationBarHidden(true)
    }
}

/// Uppercase ochre section kicker (Archivo, wide tracking) — matches the Android SectionLabel.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.archivo(9)).tracking(2.5).foregroundColor(Chika.ochre)
    }
}

/// A titled settings row with a trailing switch, over a soft ground — the Android ToggleRow.
private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @EnvironmentObject private var settings: ChikaSettings

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.archivo(14)).foregroundColor(Chika.cream)
                Text(subtitle)
                    .font(.archivo(10.5)).lineSpacing(3).foregroundColor(Chika.creamMuted)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Chika.ochre)
        }
        .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 10))
        .background(settings.groundSoft)
        .clipShape(RoundedCornerShape(cornerRadius: 6))
    }
}

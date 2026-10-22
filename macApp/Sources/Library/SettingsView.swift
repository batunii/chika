import SwiftUI

/// Chika settings / about (⌘,): the port of the iOS MenuView (itself Android's MenuScreen.kt).
/// Holds the AMOLED theme toggle, the night filter, the default reading direction and the
/// about/support section, over the ink ground with a faint crimson halftone.
struct SettingsView: View {
    @EnvironmentObject private var settings: ChikaSettings

    /// Points at the project repository.
    private static let repoURL = URL(string: "https://github.com/batunii/chika")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            settings.ground.ignoresSafeArea()
            Halftone(color: Chika.crimson, alpha: 0.05).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OchreBadge(text: "Settings")
                        .padding(.top, 8)

                    Spacer().frame(height: 28)

                    // ---- Theme -------------------------------------------------------
                    SectionLabel("THEME")
                    Spacer().frame(height: 10)
                    ToggleRow(
                        title: "AMOLED Black",
                        subtitle: "True-black background, easy on OLED screens and battery.",
                        isOn: $settings.amoled
                    )
                    Spacer().frame(height: 10)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Night filter").font(.archivo(14, weight: 700)).foregroundColor(Chika.cream)
                            Text("Changes the pages, not the app, for reading late. ⌥⌘N cycles it in the reader.")
                                .font(.archivo(10.5, weight: 500)).lineSpacing(3).foregroundColor(Chika.creamMuted)
                        }
                        Spacer(minLength: 0)
                        Picker("Night filter", selection: $settings.nightFilter) {
                            ForEach(NightFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Invert, sepia or dim the reader's pages (dim darkens around the panel in Panels mode)")
                        .accessibilityLabel("Night filter")
                    }
                    .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 10))
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 6))

                    Spacer().frame(height: 24)

                    // ---- Reading -----------------------------------------------------
                    SectionLabel("READING")
                    Spacer().frame(height: 10)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default direction").font(.archivo(14, weight: 700)).foregroundColor(Chika.cream)
                            Text("For comics you haven't opened yet. Each comic remembers its own.")
                                .font(.archivo(10.5, weight: 500)).lineSpacing(3).foregroundColor(Chika.creamMuted)
                        }
                        Spacer(minLength: 0)
                        Picker("Default direction", selection: $settings.defaultRightToLeft) {
                            Text("LTR").tag(false)
                            Text("RTL").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 10))
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 6))

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
                                .font(.system(size: 18)).foregroundColor(Chika.cream)
                            Text("SUPPORT / DONATE")
                                .font(.anton(15)).tracking(0.5).foregroundColor(Chika.cream)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Chika.crimson)
                        .clipShape(RoundedCornerShape(cornerRadius: 4))
                        .comicShadow(offset: 4, color: .black.opacity(0.6), corner: 4)
                    }
                    .buttonStyle(.plain)
                    Spacer().frame(height: 6)
                    Link(destination: Self.repoURL) {
                        Text("github.com/batunii/chika")
                            .font(.archivo(11)).foregroundColor(Chika.ochre)
                            .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .frame(width: 480, height: 620)
        .preferredColorScheme(.dark)
    }
}

/// Uppercase ochre section kicker (Archivo, wide tracking), matching the Android SectionLabel.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.archivo(9, weight: 800)).tracking(2.5).foregroundColor(Chika.ochre)
    }
}

/// A titled settings row with a trailing switch. Clicking anywhere on the row toggles it, and the
/// ground stays ink-soft even in AMOLED (matching Android's hardcoded InkSoft row).
private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.archivo(14, weight: 700)).foregroundColor(Chika.cream)
                Text(subtitle)
                    .font(.archivo(10.5, weight: 500)).lineSpacing(3).foregroundColor(Chika.creamMuted)
            }
            Spacer(minLength: 0)
            ChikaSwitch(isOn: $isOn)
        }
        .padding(.init(top: 12, leading: 16, bottom: 12, trailing: 10))
        .background(Chika.inkSoft)
        .clipShape(RoundedCornerShape(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }
    }
}

/// Brand-styled switch: ochre track + ink thumb when on, ink track + muted-cream thumb when off,
/// matching Android's SwitchDefaults colors (stock SwiftUI Toggle can't recolor the thumb).
private struct ChikaSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Chika.ochre : Chika.ink)
                .overlay(Capsule().stroke(isOn ? Chika.ochre : Chika.creamMuted, lineWidth: 2))
            Circle()
                .fill(isOn ? Chika.ink : Chika.creamMuted)
                .padding(3)
        }
        .frame(width: 46, height: 28)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }
    }
}

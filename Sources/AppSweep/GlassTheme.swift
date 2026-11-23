import SwiftUI

/// Optional Liquid Glass theme (macOS 26+). Off by default; with it off the UI is unchanged.
enum GlassTheme {
    static let key = "glassTheme"
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// A floating chrome bar (header/footer over the file list). Plain: the original edge-to-edge `.bar` strip.
    /// Glass: an inset, rounded glass panel the list scrolls underneath.
    @ViewBuilder
    func sweepBar(glass: Bool, edge: VerticalEdge) -> some View {
        if glass, #available(macOS 26, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(edge == .top ? .top : .bottom, 10)
                .padding(edge == .top ? .bottom : .top, 6)
        } else {
            VStack(spacing: 0) {
                if edge == .bottom { Divider() }
                self
                if edge == .top { Divider() }
            }
            .background(.bar)
        }
    }

    /// A content card. Plain: the original soft fill. Glass: a glass card.
    @ViewBuilder
    func sweepCard(glass: Bool) -> some View {
        if glass, #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            self.background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Prominent action button. Plain: `.borderedProminent`. Glass: `.glassProminent`.
    @ViewBuilder
    func sweepProminentButton(glass: Bool) -> some View {
        if glass, #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

struct SettingsView: View {
    @AppStorage(GlassTheme.key) private var glassTheme = false

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle(isOn: $glassTheme) {
                    Text("Liquid Glass theme")
                    Text(GlassTheme.isSupported
                         ? "Use Liquid Glass for headers, toolbars and cards."
                         : "Requires macOS 26.")
                }
                .disabled(!GlassTheme.isSupported)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

import SwiftUI
import UIKit

/// One shared palette: system appearance, readable text and semantic state colors.
enum AppTheme {
    static let canvas = adaptive(light: 0xF4F5F0, dark: 0x101A17)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B2923)
    static let raised = adaptive(light: 0xE9EFE7, dark: 0x25382E)
    static let accent = adaptive(light: 0x285D49, dark: 0x9DD7B7)
    static let buttonFill = Color(red: 0.14, green: 0.36, blue: 0.28)
    static let ink = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
    static let border = Color(uiColor: .separator).opacity(0.3)
    static let recording = adaptive(light: 0xA84435, dark: 0xFFAA97)
    static let warning = adaptive(light: 0x805410, dark: 0xF1C77F)
    static let radius: CGFloat = 24
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { traits in color(traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radius).stroke(AppTheme.border, lineWidth: 0.7))
    }
}
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 16).padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(AppTheme.buttonFill.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
struct StatusPill: View {
    let text: String
    let icon: String
    var color: Color = AppTheme.accent
    var body: some View {
        Label(text, systemImage: icon).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(color).background(color.opacity(0.10), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}
struct SectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(AppTheme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct FeatureRoute: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44).background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(AppTheme.ink)
                Text(detail).font(.caption).foregroundStyle(AppTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(AppTheme.muted)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border, lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

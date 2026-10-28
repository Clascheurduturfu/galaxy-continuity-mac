import SwiftUI
import AppKit

public enum AppVersion {
    public static let appName = "Galaxy Continuity"
    public static let short = "1.1-beta.4"
    public static let display = "v1.1 beta 4"
    public static let full = display
    public static var isRenderingDemo: Bool { CommandLine.arguments.contains("--render-screenshots") }
    public static var isWindowSelfTest: Bool { CommandLine.arguments.contains("--window-lifecycle-selftest") }
}

public enum OneUI {
    public static let blue = Color(red: 0.24, green: 0.57, blue: 1.00)       // #3E91FF
    public static let deepBlue = Color(red: 0.14, green: 0.42, blue: 0.92)   // #246BEB
    public static let green = Color(red: 0.10, green: 0.71, blue: 0.42)      // #19B56B
    public static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)      // #F59E0B
    public static let red = Color(red: 0.94, green: 0.29, blue: 0.30)        // #F04A4C
    public static let cardRadius: CGFloat = 22
    public static let tileRadius: CGFloat = 18

    public static func canvasBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.07, green: 0.08, blue: 0.10)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }

    public static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.13, blue: 0.16)
            : Color.white
    }

    public static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.21)
            : Color(red: 0.96, green: 0.97, blue: 0.99)
    }

    public static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }
}

public enum StatusTone {
    case connected
    case active
    case warning
    case error
    case neutral

    public var color: Color {
        switch self {
        case .connected: return OneUI.green
        case .active: return OneUI.blue
        case .warning: return OneUI.amber
        case .error: return OneUI.red
        case .neutral: return .secondary
        }
    }
}

public struct OneUIStatusPill: View {
    public let label: String
    public let tone: StatusTone
    public var symbol: String? = nil

    public init(_ label: String, tone: StatusTone, symbol: String? = nil) {
        self.label = label
        self.tone = tone
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Circle()
                    .fill(tone.color)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tone.color.opacity(tone == .neutral ? 0.10 : 0.14))
        )
    }
}

public struct OneUICard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OneUI.cardRadius, style: .continuous)
                    .fill(OneUI.cardBackground(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: OneUI.cardRadius, style: .continuous)
                            .strokeBorder(OneUI.cardBorder(scheme), lineWidth: 1)
                    )
            )
    }
}

public struct OneUIPageHeader<Trailing: View>: View {
    public let title: String
    public let subtitle: String
    private let trailing: Trailing

    public init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: 12) { heading; trailing }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OneUIPageHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

public struct OneUIQuickTile: View {
    @Environment(\.colorScheme) private var scheme
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let isOn: Bool
    public var isBusy: Bool = false
    public var isDisabled: Bool = false
    public let action: () -> Void

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            isOn
                                ? LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 40, height: 40)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isOn ? .white : .primary)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isOn ? OneUI.blue : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: OneUI.tileRadius, style: .continuous)
                    .fill(isOn ? OneUI.blue.opacity(scheme == .dark ? 0.16 : 0.10) : OneUI.cardBackground(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: OneUI.tileRadius, style: .continuous)
                            .strokeBorder(isOn ? OneUI.blue.opacity(0.38) : OneUI.cardBorder(scheme), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

public struct OneUIPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public var tint: Color = OneUI.blue
    public init(tint: Color = OneUI.blue) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled ? tint.opacity(configuration.isPressed ? 0.82 : 1.0) : Color.secondary.opacity(0.12))
            )
    }
}

public struct OneUISecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(OneUI.elevatedBackground(scheme).opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(OneUI.cardBorder(scheme), lineWidth: 1)
                    )
            )
    }
}

/// A consistent trailing switch, independent of macOS' intrinsic Toggle label layout.
struct OneUIAlignedSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 }))
                .toggleStyle(.switch).labelsHidden().fixedSize()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

enum AppTheme {
    static let shellTop = Color(red: 0.97, green: 0.97, blue: 0.96)
    static let shellBottom = Color(red: 0.91, green: 0.91, blue: 0.89)
    static let shellGlow = Color(red: 0.86, green: 0.86, blue: 0.83)
    static let shellMist = Color.white.opacity(0.72)

    static let panel = Color.white.opacity(0.94)
    static let panelStrong = Color.white.opacity(0.985)
    static let panelMuted = Color(red: 0.93, green: 0.93, blue: 0.91)
    static let rail = Color(red: 0.14, green: 0.14, blue: 0.14)
    static let stroke = Color.black.opacity(0.11)
    static let strokeStrong = Color.black.opacity(0.18)

    static let textPrimary = Color.black.opacity(0.92)
    static let textSecondary = Color.black.opacity(0.63)
    static let textMuted = Color.black.opacity(0.44)
    static let textGhost = Color.black.opacity(0.22)

    static let accent = Color.black
    static let accentCopper = Color(red: 0.82, green: 0.45, blue: 0.16)
    static let accentAcid = Color(red: 0.29, green: 0.52, blue: 0.31)
    static let success = Color(red: 0.19, green: 0.45, blue: 0.21)
    static let warning = Color(red: 0.69, green: 0.42, blue: 0.10)
    static let danger = Color(red: 0.62, green: 0.16, blue: 0.15)

    static let ferroBlack = Color(red: 0.03, green: 0.03, blue: 0.03)
    static let ferroPanel = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let ferroStroke = Color.white.opacity(0.09)
    static let ferroTextPrimary = Color.white.opacity(0.92)
    static let ferroTextSecondary = Color.white.opacity(0.58)

    static let fluidShadow = Color.black.opacity(0.22)
}

enum AppTypography {
    static func title(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .black, design: .monospaced)
    }

    static func heading(_ size: CGFloat = 19) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }

    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static func caption(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.shellTop, AppTheme.shellBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            TerminalGridOverlay()
                .stroke(AppTheme.stroke.opacity(0.08), lineWidth: 0.5)
                .ignoresSafeArea()

            UnevenRoundedRectangle(topLeadingRadius: 64, bottomLeadingRadius: 140, bottomTrailingRadius: 76, topTrailingRadius: 120)
                .fill(AppTheme.shellGlow.opacity(0.34))
                .frame(width: 300, height: 240)
                .blur(radius: 36)
                .offset(x: 120, y: -220)

            Circle()
                .fill(AppTheme.shellMist)
                .frame(width: 180, height: 180)
                .blur(radius: 58)
                .offset(x: -120, y: 280)
        }
    }
}

struct SessionBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.ferroBlack, Color(red: 0.08, green: 0.08, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
                .offset(x: -90, y: -260)

            UnevenRoundedRectangle(topLeadingRadius: 120, bottomLeadingRadius: 70, bottomTrailingRadius: 160, topTrailingRadius: 90)
                .fill(Color.white.opacity(0.05))
                .frame(width: 320, height: 280)
                .blur(radius: 42)
                .offset(x: 110, y: 260)
        }
    }
}

struct TerminalGridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 28
        var x: CGFloat = 0
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y: CGFloat = 0
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        return path
    }
}

struct AppPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.strokeStrong, lineWidth: 1)
            )
            .shadow(color: AppTheme.fluidShadow.opacity(0.08), radius: 10, x: 0, y: 8)
    }
}

struct FerroPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.ferroPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.ferroStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 14)
    }
}

extension View {
    func appPanel() -> some View {
        modifier(AppPanelModifier())
    }

    func ferroPanel() -> some View {
        modifier(FerroPanelModifier())
    }
}

struct PrimaryPillButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.heading(16))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.94 : 0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.rail.opacity(configuration.isPressed ? 0.82 : (isEnabled ? 1.0 : 0.38)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryPillButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.body(15))
            .foregroundStyle(isEnabled ? AppTheme.textPrimary : AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.panelStrong.opacity(configuration.isPressed ? 0.72 : (isEnabled ? 1.0 : 0.55)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.strokeStrong.opacity(isEnabled ? 1.0 : 0.5), lineWidth: 1)
            )
    }
}

struct DangerPillButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.heading(16))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.94 : 0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.danger.opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1.0 : 0.38)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }
}

struct SessionButtonStyle: ButtonStyle {
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.5)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct SessionButton: View {
    let isActive: Bool
    let isEnabled: Bool

    private var borderColor: Color {
        if !isEnabled { return Color.white.opacity(0.06) }
        return isActive ? AppTheme.accentCopper.opacity(0.35) : Color.white.opacity(0.10)
    }

    private var glowColor: Color {
        isActive ? AppTheme.accentCopper.opacity(0.12) : Color.white.opacity(0.04)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isEnabled)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * (isActive ? 4.2 : 2.1)) + 1.0) / 2.0

            ZStack {
                // Base shape
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.ferroBlack)

                // Subtle inner glow
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(glowColor)
                    .blur(radius: 8)
                    .padding(2)

                // Pulsing border
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        borderColor.opacity(0.6 + breathe * 0.4),
                        lineWidth: isActive ? 1.5 : 1.0
                    )

                // Content
                VStack(spacing: 14) {
                    Text(isActive ? "[ ACTIVE ]" : "[ START ]")
                        .font(AppTypography.caption(10))
                        .foregroundStyle(
                            isActive
                                ? AppTheme.accentCopper.opacity(0.7)
                                : Color.white.opacity(0.45)
                        )
                        .tracking(2.0)

                    Text(isActive ? "END SESSION" : "START SESSION")
                        .font(AppTypography.heading(22))
                        .foregroundStyle(
                            isActive
                                ? AppTheme.danger
                                : Color.white.opacity(0.92)
                        )
                        .tracking(1.4)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(isActive ? AppTheme.accentAcid : AppTheme.accentCopper)
                            .frame(width: 6, height: 6)
                            .shadow(
                                color: isActive ? AppTheme.accentAcid.opacity(0.5) : Color.clear,
                                radius: 4
                            )

                        Text(isActive ? "SESSION LIVE" : "READY")
                            .font(AppTypography.caption(10))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .tracking(1.2)
                    }
                }
            }
        }
    }
}

struct TerminalKicker: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(AppTypography.caption(11))
            .tracking(1.8)
            .foregroundStyle(tint)
    }
}

struct TerminalSectionHeader: View {
    let kicker: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TerminalKicker(text: kicker, tint: AppTheme.textSecondary)
            Text(title)
                .font(AppTypography.title(28))
                .foregroundStyle(AppTheme.textPrimary)
            Text(detail)
                .font(AppTypography.body(15))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TerminalTabBar: View {
    let items: [TerminalTabItem]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    VStack(spacing: 4) {
                        Text(item.marker)
                            .font(AppTypography.heading(14))
                        Text(item.label)
                            .font(AppTypography.caption(10))
                            .tracking(1.2)
                    }
                    .foregroundStyle(selected == item.id ? Color.white : AppTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected == item.id ? AppTheme.rail : AppTheme.panelStrong)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected == item.id ? Color.white.opacity(0.08) : AppTheme.strokeStrong, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.panel.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.strokeStrong, lineWidth: 1)
        )
    }
}

struct TerminalTabItem: Identifiable {
    let id: String
    let marker: String
    let label: String
}

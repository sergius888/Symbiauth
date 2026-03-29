import SwiftUI

struct ChamberTerminalTheme {
    static let panelFill = Color(red: 0.03, green: 0.03, blue: 0.03)
    static let panelStroke = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let rowFill = Color(red: 0.045, green: 0.045, blue: 0.045)
    static let rowHover = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let textPrimary = Color(red: 0.84, green: 0.84, blue: 0.84)
    static let textSecondary = Color(red: 0.36, green: 0.36, blue: 0.36)
    static let textMuted = Color(red: 0.22, green: 0.22, blue: 0.22)
    static let textGhost = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let accentCopper = Color(red: 0.93, green: 0.54, blue: 0.26)
    static let accentAcid = Color(red: 0.53, green: 0.73, blue: 0.58)
    static let accentRail = Color(red: 0.91, green: 0.91, blue: 0.91)
    static let noiseFill = Color(red: 0.08, green: 0.08, blue: 0.08)
}

extension Font {
    static func chamberMono(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

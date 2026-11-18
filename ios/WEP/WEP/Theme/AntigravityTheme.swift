import SwiftUI

enum AgyTheme {
    static let bgCanvas = Color(hex: 0x0B0D12)
    static let bgSidebar = Color(hex: 0x12151E)
    static let bgCard = Color(hex: 0x171B26)
    static let bgElevated = Color(hex: 0x1F2433)
    static let bgInput = Color(hex: 0x0E1118)
    static let borderSubtle = Color(hex: 0x262B3D)

    static let textPrimary = Color(hex: 0xF3F4F6)
    static let textSecondary = Color(hex: 0x9CA3AF)
    static let textMuted = Color(hex: 0x6B7280)

    static let accentIndigo = Color(hex: 0x6366F1)
    static let accentCyan = Color(hex: 0x38BDF8)
    static let success = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)

    static let brandGradient = LinearGradient(
        colors: [accentIndigo, accentCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

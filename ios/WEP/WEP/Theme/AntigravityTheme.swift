import SwiftUI
import UIKit

enum AgyTheme {
    static let bgCanvas = Color(hex: 0x090B10)
    static let bgSidebar = Color(hex: 0x10141E)
    static let bgCard = Color(hex: 0x151A28)
    static let bgElevated = Color(hex: 0x1D2437)
    static let bgInput = Color(hex: 0x0C0F17)
    static let borderSubtle = Color(hex: 0x252D42)

    static let textPrimary = Color(hex: 0xF3F4F6)
    static let textSecondary = Color(hex: 0x9CA3AF)
    static let textMuted = Color(hex: 0x6B7280)

    static let accentIndigo = Color(hex: 0x6366F1)
    static let accentCyan = Color(hex: 0x38BDF8)
    static let accentCodex = Color(hex: 0x10B981)
    static let accentViolet = Color(hex: 0xA855F7)
    static let success = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)

    static let brandGradient = LinearGradient(
        colors: [accentIndigo, accentCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let codexGradient = LinearGradient(
        colors: [accentCodex, Color(hex: 0x14B8A6)],
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

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

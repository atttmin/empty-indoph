//
//  EmptyTheme.swift
//  Empty
//
//  "朱批 Vermilion" design system from the Empty. 空 prototypes:
//  warm-paper light theme, night-read dark theme, vermilion accent.
//  空是底，朱是点 — the app is the empty room, AI is the dot of
//  vermilion in its margins.
//

import SwiftUI

/// Resolved color tokens for one theme. Token names follow the prototype
/// (`cInk`, `cAcc`, …) so values stay traceable to the design source.
nonisolated struct EmptyPalette: Equatable {
    var isDark: Bool

    /// Window background (the "paper" of the app shell).
    var window: Color
    /// Sidebar / inset panel background.
    var side: Color
    /// Card surfaces sitting on the window.
    var card: Color

    /// Primary text.
    var ink: Color
    /// Secondary text.
    var ink2: Color
    /// Tertiary text / placeholders.
    var ink3: Color

    /// Hairline separators.
    var line: Color
    /// Stronger borders (controls).
    var line2: Color

    /// Vermilion accent — reserved for AI presence and key actions.
    var accent: Color
    /// Accent wash backgrounds.
    var accentSoft: Color
    /// Stronger accent wash (selected underlines, borders).
    var accentSoft2: Color
    /// Text/glyphs placed on solid accent fills.
    var onAccent: Color

    /// Reader highlight underlay (faded gold).
    var highlight: Color
    /// Card shadows.
    var shadow: Color

    static let light = EmptyPalette(
        isDark: false,
        window: Color(hex: 0xF7F2E9),
        side: Color(hex: 0xF0E9DC),
        card: .white,
        ink: Color(hex: 0x2A2419),
        ink2: Color(hex: 0x5C5443),
        ink3: Color(hex: 0x988E7D),
        line: Color(hex: 0xE3DACA),
        line2: Color(hex: 0xD8CEBB),
        accent: Color(hex: 0xB5482A),
        accentSoft: Color(hex: 0xB5482A, opacity: 0.08),
        accentSoft2: Color(hex: 0xB5482A, opacity: 0.16),
        onAccent: Color(hex: 0xFFF6EC),
        highlight: Color(hex: 0xDEB248, opacity: 0.4),
        shadow: Color(hex: 0x1F1B16, opacity: 0.12)
    )

    static let dark = EmptyPalette(
        isDark: true,
        window: Color(hex: 0x1F1B16),
        side: Color(hex: 0x262019),
        card: Color(hex: 0x2A241C),
        ink: Color(hex: 0xEDE5D4),
        ink2: Color(hex: 0xC4B9A4),
        ink3: Color(hex: 0x8A8070),
        line: Color(hex: 0x352E24),
        line2: Color(hex: 0x453C2F),
        accent: Color(hex: 0xD86B47),
        accentSoft: Color(hex: 0xD86B47, opacity: 0.12),
        accentSoft2: Color(hex: 0xD86B47, opacity: 0.22),
        onAccent: Color(hex: 0xFFF6EC),
        highlight: Color(hex: 0xDEB248, opacity: 0.28),
        shadow: Color(hex: 0x000000, opacity: 0.45)
    )
}

extension EnvironmentValues {
    @Entry var emptyPalette: EmptyPalette = .light
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Brand mark

/// The Empty. logo: a single-stroke ensō with its gap to the upper right
/// ("进行时,还在读") and a vermilion dot living inside the emptiness.
struct EnsoMark: View {
    var size: CGFloat = 30

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.873)
                .stroke(
                    palette.ink,
                    style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round)
                )
                .rotationEffect(.degrees(-45))
                .padding(size * 0.15)
            Circle()
                .fill(palette.accent)
                .frame(width: size * 0.11, height: size * 0.11)
        }
        .frame(width: size, height: size)
    }
}

/// The square 朱 badge that marks AI presence everywhere in the UI.
struct ZhuBadge: View {
    var size: CGFloat = 18

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        Text("朱")
            .font(.system(size: size * 0.55, weight: .black, design: .serif))
            .foregroundStyle(palette.onAccent)
            .frame(width: size, height: size)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

// MARK: - Shared styling

extension View {
    /// Card surface per the design: card fill, hairline border, soft shadow.
    func emptyCard(_ palette: EmptyPalette, radius: CGFloat = 16) -> some View {
        background(palette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(palette.line, lineWidth: 1)
            )
            .shadow(color: palette.shadow, radius: 10, y: 6)
    }

    /// Pill chip: small caps-ish label on a soft background.
    func emptyChip(foreground: Color, background: Color) -> some View {
        font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

/// 朱批 callout: accent-washed block with a vermilion left rule, used for
/// AI margin notes, "last read" teasers and revealed vocabulary answers.
struct ZhupiCallout<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(palette.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            palette.accentSoft,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 12, topTrailingRadius: 12
            )
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.accent).frame(width: 2)
        }
    }
}

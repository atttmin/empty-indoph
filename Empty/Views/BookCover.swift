//
//  BookCover.swift
//  Empty
//
//  Shared cover rendering: the prototype's deterministic placeholder
//  palette plus a cross-platform cover view used by the iOS shelf and
//  hero cards (the Mac shelf has its own larger-scale rendering).
//

import SwiftUI

/// Deterministic placeholder-cover styling, modeled on the prototype's
/// shelf (forest green, navy, parchment, gold, lacquer black).
nonisolated struct CoverStyle {
    let background: Color
    let foreground: Color

    static let all: [CoverStyle] = [
        CoverStyle(background: Color(hex: 0x3E4F3A), foreground: Color(hex: 0xE8E4D2)),
        CoverStyle(background: Color(hex: 0x2E3A56), foreground: Color(hex: 0xD8DCE8)),
        CoverStyle(background: Color(hex: 0xEFE6D2), foreground: Color(hex: 0x1F1B16)),
        CoverStyle(background: Color(hex: 0xC9A86A), foreground: Color(hex: 0x3A2E18)),
        CoverStyle(background: Color(hex: 0x211D19), foreground: Color(hex: 0xC9A86A)),
        CoverStyle(background: Color(hex: 0x1B2B4A), foreground: Color(hex: 0xD9B65C)),
    ]

    static func style(for title: String) -> CoverStyle {
        var hash: UInt64 = 5381
        for byte in title.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return all[Int(hash % UInt64(all.count))]
    }
}

/// Phone-scale book cover: real thumbnail when present, else the designed
/// placeholder (uppercase author, serif title, EMPTY 藏本 colophon) at the
/// prototype's 76×108 proportions.
struct SharedBookCover: View {
    let book: Book

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        Group {
            if let data = book.coverThumbnailData, let image = Self.platformImage(data) {
                Color.clear
                    .aspectRatio(76 / 108, contentMode: .fit)
                    .overlay {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: palette.shadow, radius: 7, y: 5)
    }

    private var placeholder: some View {
        let style = CoverStyle.style(for: book.title)
        return VStack(alignment: .leading, spacing: 0) {
            if !book.author.isEmpty {
                Text(book.author.uppercased())
                    .font(.system(size: 5.5))
                    .kerning(1.4)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Text(book.title)
                .font(.system(size: 12, weight: .bold, design: .serif))
                .lineLimit(4)
                .padding(.top, 5)
            Spacer(minLength: 0)
            Rectangle()
                .fill(style.foreground.opacity(0.35))
                .frame(height: 1)
                .padding(.bottom, 4)
            Text("EMPTY 藏本")
                .font(.system(size: 5))
                .kerning(1.4)
                .opacity(0.6)
        }
        .foregroundStyle(style.foreground)
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .aspectRatio(76 / 108, contentMode: .fit)
        .background(style.background)
    }

    private static func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

//
//  NativeSelectableTextBlockView.swift
//  Empty
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias NativePlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias NativePlatformColor = NSColor
#endif

nonisolated enum NativeTextWeight: Equatable {
    case regular
    case bold
}

nonisolated enum NativeTextTone: Equatable {
    case primary
    case secondary
}

private nonisolated struct NativeHighlightSegment: Equatable {
    var startUTF16: Int
    var endUTF16: Int
}

private nonisolated struct NativeTextRenderModel: Equatable {
    var text: String
    var fontSize: Double
    var lineSpacing: CGFloat
    var weight: NativeTextWeight
    var tone: NativeTextTone
    var isDark: Bool
    var highlightSegments: [NativeHighlightSegment]
}

struct NativeSelectableTextBlockView: View {
    let text: String
    let fontSize: Double
    let lineSpacing: CGFloat
    let weight: NativeTextWeight
    let tone: NativeTextTone
    let highlightRanges: [Range<Int>]
    let isDark: Bool
    var clearSelection: Bool = false
    var onSelectionChange: (Range<Int>?) -> Void = { _ in }

    var body: some View {
        NativeSelectableTextRepresentable(
            model: NativeTextRenderModel(
                text: text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                weight: weight,
                tone: tone,
                isDark: isDark,
                highlightSegments: highlightRanges.map {
                    NativeHighlightSegment(
                        startUTF16: $0.lowerBound,
                        endUTF16: $0.upperBound
                    )
                }
            ),
            clearSelection: clearSelection,
            onSelectionChange: onSelectionChange
        )
    }
}

private func makeAttributedText(from model: NativeTextRenderModel) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = model.lineSpacing
    paragraph.paragraphSpacing = 0

    let attributes: [NSAttributedString.Key: Any] = [
        .font: nativeFont(size: model.fontSize, weight: model.weight),
        .foregroundColor: nativeTextColor(tone: model.tone, isDark: model.isDark),
        .paragraphStyle: paragraph,
    ]
    let attributed = NSMutableAttributedString(string: model.text, attributes: attributes)
    let textLength = model.text.utf16.count
    let highlight = nativeHighlightColor(isDark: model.isDark)
    for segment in model.highlightSegments {
        let clampedStart = max(0, min(segment.startUTF16, textLength))
        let clampedEnd = max(clampedStart, min(segment.endUTF16, textLength))
        guard clampedEnd > clampedStart else { continue }
        attributed.addAttribute(
            .backgroundColor,
            value: highlight,
            range: NSRange(location: clampedStart, length: clampedEnd - clampedStart)
        )
    }
    return attributed
}

private func nativeTextColor(
    tone: NativeTextTone,
    isDark: Bool
) -> NativePlatformColor {
    switch (tone, isDark) {
    case (.primary, false): return NativePlatformColor(hex: 0x2A2419)
    case (.secondary, false): return NativePlatformColor(hex: 0x5C5443)
    case (.primary, true): return NativePlatformColor(hex: 0xEDE5D4)
    case (.secondary, true): return NativePlatformColor(hex: 0xC4B9A4)
    }
}

private func nativeHighlightColor(isDark: Bool) -> NativePlatformColor {
    NativePlatformColor(hex: 0xDEB248, alpha: isDark ? 0.28 : 0.4)
}

#if canImport(UIKit)
private func nativeFont(size: Double, weight: NativeTextWeight) -> UIFont {
    let uiWeight: UIFont.Weight = weight == .bold ? .bold : .regular
    let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
    guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
    return UIFont(descriptor: descriptor, size: size)
}

private struct NativeSelectableTextRepresentable: UIViewRepresentable {
    let model: NativeTextRenderModel
    let clearSelection: Bool
    let onSelectionChange: (Range<Int>?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.contentInset = .zero
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.attributedText = makeAttributedText(from: model)
        context.coordinator.model = model
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if context.coordinator.model != model {
            context.coordinator.programmaticChange = true
            textView.attributedText = makeAttributedText(from: model)
            context.coordinator.programmaticChange = false
            context.coordinator.model = model
        }
        if clearSelection, textView.selectedRange.length > 0 {
            context.coordinator.programmaticChange = true
            textView.selectedRange = NSRange(location: NSNotFound, length: 0)
            context.coordinator.programmaticChange = false
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var model: NativeTextRenderModel?
        var programmaticChange = false
        let onSelectionChange: (Range<Int>?) -> Void

        init(onSelectionChange: @escaping (Range<Int>?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !programmaticChange else { return }
            let selection = textView.selectedRange
            guard selection.location != NSNotFound, selection.length > 0 else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(selection.location..<(selection.location + selection.length))
        }
    }
}
#elseif canImport(AppKit)
private func nativeFont(size: Double, weight: NativeTextWeight) -> NSFont {
    let nsWeight: NSFont.Weight = weight == .bold ? .bold : .regular
    let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
    guard let descriptor = base.fontDescriptor.withDesign(.serif),
          let font = NSFont(descriptor: descriptor, size: size) else {
        return base
    }
    return font
}

private struct NativeSelectableTextRepresentable: NSViewRepresentable {
    let model: NativeTextRenderModel
    let clearSelection: Bool
    let onSelectionChange: (Range<Int>?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textStorage?.setAttributedString(makeAttributedText(from: model))
        context.coordinator.model = model
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if context.coordinator.model != model {
            context.coordinator.programmaticChange = true
            textView.textStorage?.setAttributedString(makeAttributedText(from: model))
            context.coordinator.programmaticChange = false
            context.coordinator.model = model
        }
        if clearSelection, textView.selectedRange().length > 0 {
            context.coordinator.programmaticChange = true
            textView.setSelectedRange(NSRange(location: NSNotFound, length: 0))
            context.coordinator.programmaticChange = false
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0,
              let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(
            width: width,
            height: ceil(used.height + nsView.textContainerInset.height * 2 + 1)
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: NativeTextRenderModel?
        var programmaticChange = false
        let onSelectionChange: (Range<Int>?) -> Void

        init(onSelectionChange: @escaping (Range<Int>?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !programmaticChange,
                  let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.length > 0 else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(selection.location..<(selection.location + selection.length))
        }
    }
}
#endif

private extension NativePlatformColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

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

/// One highlight's footprint inside a text block, with its marker tint.
nonisolated struct NativeHighlightRange: Equatable {
    var range: Range<Int>
    var colorHex: UInt32

    init(range: Range<Int>, colorHex: UInt32 = 0xE5C55E) {
        self.range = range
        self.colorHex = colorHex
    }
}

private nonisolated struct NativeHighlightSegment: Equatable {
    var startUTF16: Int
    var endUTF16: Int
    var colorHex: UInt32
}

private nonisolated struct NativeTextSelectionRequest: Equatable {
    var startUTF16: Int
    var endUTF16: Int
}

private nonisolated struct NativeTextRenderModel: Equatable {
    var text: String
    var fontSize: Double
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var headIndent: CGFloat
    var firstLineHeadIndent: CGFloat
    var weight: NativeTextWeight
    var tone: NativeTextTone
    var justified = false
    var isDark: Bool
    var monospaced = false
    var fontFamily: String? = nil
    var useSerifDesign = true
    var inkPrimaryHex: UInt32? = nil
    var inkSecondaryHex: UInt32? = nil
    var highlightSegments: [NativeHighlightSegment]
    /// Number of leading characters rendered at `dropCapFontSize` for a
    /// book-style drop-cap opening paragraph.
    var dropCapCount: Int = 0
    var dropCapFontSize: Double? = nil
}

struct NativeSelectableTextBlockView: View {
    let text: String
    let fontSize: Double
    let lineSpacing: CGFloat
    var paragraphSpacing: CGFloat = 0
    var headIndent: CGFloat = 0
    var firstLineHeadIndent: CGFloat = 0
    let weight: NativeTextWeight
    let tone: NativeTextTone
    let highlightRanges: [NativeHighlightRange]
    let isDark: Bool
    var justified = false
    var monospaced: Bool = false
    var fontFamily: String? = nil
    var useSerifDesign: Bool = true
    var inkPrimaryHex: UInt32? = nil
    var inkSecondaryHex: UInt32? = nil
    var selectedRange: Range<Int>? = nil
    var scrollTargetOffset: Int? = nil
    var clearSelection: Bool = false
    /// Book-style drop cap: render the first N characters at a larger size.
    var dropCapCount: Int = 0
    var dropCapFontSize: Double? = nil
    var onSelectionChange: (Range<Int>?) -> Void = { _ in }

    var body: some View {
        NativeSelectableTextRepresentable(
            model: NativeTextRenderModel(
                text: text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                headIndent: headIndent,
                firstLineHeadIndent: firstLineHeadIndent,
                weight: weight,
                tone: tone,
                justified: justified,
                isDark: isDark,
                monospaced: monospaced,
                fontFamily: fontFamily,
                useSerifDesign: useSerifDesign,
                inkPrimaryHex: inkPrimaryHex,
                inkSecondaryHex: inkSecondaryHex,
                highlightSegments: highlightRanges.map {
                    NativeHighlightSegment(
                        startUTF16: $0.range.lowerBound,
                        endUTF16: $0.range.upperBound,
                        colorHex: $0.colorHex
                    )
                },
                dropCapCount: dropCapCount,
                dropCapFontSize: dropCapFontSize
            ),
            selectedRange: selectedRange.map {
                NativeTextSelectionRequest(startUTF16: $0.lowerBound, endUTF16: $0.upperBound)
            },
            scrollTargetOffset: scrollTargetOffset,
            clearSelection: clearSelection,
            onSelectionChange: onSelectionChange
        )
    }
}

private func makeAttributedText(from model: NativeTextRenderModel) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = model.lineSpacing
    paragraph.paragraphSpacing = model.paragraphSpacing
    paragraph.headIndent = model.headIndent
    paragraph.firstLineHeadIndent = model.firstLineHeadIndent
    paragraph.alignment = model.justified ? .justified : .natural
    let attributes: [NSAttributedString.Key: Any] = [
        .font: nativeFont(
            size: model.fontSize,
            weight: model.weight,
            monospaced: model.monospaced,
            family: model.fontFamily,
            useSerifDesign: model.useSerifDesign
        ),
        .foregroundColor: nativeTextColor(model: model),
        .paragraphStyle: paragraph,
    ]
    let attributed = NSMutableAttributedString(string: model.text, attributes: attributes)
    let textLength = model.text.utf16.count

    if model.dropCapCount > 0, let dropCapSize = model.dropCapFontSize, dropCapSize > model.fontSize {
        let capLength = min(model.dropCapCount, textLength)
        let capRange = NSRange(location: 0, length: capLength)
        let capFont = nativeFont(
            size: dropCapSize,
            weight: .bold,
            monospaced: model.monospaced,
            family: model.fontFamily,
            useSerifDesign: model.useSerifDesign
        )
        attributed.addAttribute(.font, value: capFont, range: capRange)
    }

    for segment in model.highlightSegments {
        let clampedStart = max(0, min(segment.startUTF16, textLength))
        let clampedEnd = max(clampedStart, min(segment.endUTF16, textLength))
        guard clampedEnd > clampedStart else { continue }
        let range = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
        // 视觉精修: highlights are an underline wash (底线染色), not a
        // block of background — the text face stays uninterrupted.
        attributed.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.thick.rawValue,
            range: range
        )
        attributed.addAttribute(
            .underlineColor,
            value: NativePlatformColor(
                hex: segment.colorHex,
                alpha: model.isDark ? 0.66 : 0.82
            ),
            range: range
        )
    }
    return attributed
}

private func nativeTextColor(model: NativeTextRenderModel) -> NativePlatformColor {
    switch model.tone {
    case .primary:
        if let hex = model.inkPrimaryHex { return NativePlatformColor(hex: hex) }
        return NativePlatformColor(hex: model.isDark ? 0xEDE5D4 : 0x2A2419)
    case .secondary:
        if let hex = model.inkSecondaryHex { return NativePlatformColor(hex: hex) }
        return NativePlatformColor(hex: model.isDark ? 0xC4B9A4 : 0x5C5443)
    }
}

#if canImport(UIKit)
private func nativeFont(
    size: Double,
    weight: NativeTextWeight,
    monospaced: Bool = false,
    family: String? = nil,
    useSerifDesign: Bool = true
) -> UIFont {
    let uiWeight: UIFont.Weight = weight == .bold ? .bold : .regular
    if monospaced {
        return UIFont.monospacedSystemFont(ofSize: size, weight: uiWeight)
    }
    if let family {
        var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        if weight == .bold,
           let bold = descriptor.withSymbolicTraits(.traitBold) {
            descriptor = bold
        }
        let font = UIFont(descriptor: descriptor, size: size)
        if font.familyName == family || font.fontName.contains(family.replacingOccurrences(of: " ", with: "")) {
            return font
        }
    }
    let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
    guard useSerifDesign,
          let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
    return UIFont(descriptor: descriptor, size: size)
}

private struct NativeSelectableTextRepresentable: UIViewRepresentable {
    let model: NativeTextRenderModel
    let selectedRange: NativeTextSelectionRequest?
    let scrollTargetOffset: Int?
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
            context.coordinator.selectionDebouncer.cancel()
            context.coordinator.programmaticChange = true
            textView.selectedRange = NSRange(location: NSNotFound, length: 0)
            context.coordinator.programmaticChange = false
            context.coordinator.appliedSelection = nil
        } else if let selectedRange,
                  context.coordinator.appliedSelection != selectedRange {
            context.coordinator.selectionDebouncer.cancel()
            let range = clampedNSRange(for: selectedRange, textLength: model.text.utf16.count)
            context.coordinator.programmaticChange = true
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
            context.coordinator.programmaticChange = false
            context.coordinator.appliedSelection = selectedRange
        } else if let scrollTargetOffset,
                  context.coordinator.appliedScrollTarget != scrollTargetOffset {
            let location = max(0, min(scrollTargetOffset, model.text.utf16.count))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            context.coordinator.appliedScrollTarget = scrollTargetOffset
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
        var appliedSelection: NativeTextSelectionRequest?
        var appliedScrollTarget: Int?
        let onSelectionChange: (Range<Int>?) -> Void
        let selectionDebouncer = SelectionChangeDebouncer()

        init(onSelectionChange: @escaping (Range<Int>?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !programmaticChange else { return }
            let selection = textView.selectedRange
            let range: Range<Int>? =
                if selection.location != NSNotFound, selection.length > 0 {
                    selection.location..<(selection.location + selection.length)
                } else {
                    nil
                }
            selectionDebouncer.submit(range, deliver: onSelectionChange)
        }
    }
}

#elseif canImport(AppKit)
private func nativeFont(
    size: Double,
    weight: NativeTextWeight,
    monospaced: Bool = false,
    family: String? = nil,
    useSerifDesign: Bool = true
) -> NSFont {
    let nsWeight: NSFont.Weight = weight == .bold ? .bold : .regular
    if monospaced {
        return NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight)
    }
    if let family {
        var descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if weight == .bold {
            descriptor = descriptor.withSymbolicTraits(.bold)
        }
        if let font = NSFont(descriptor: descriptor, size: size),
           font.familyName == family {
            return font
        }
    }
    let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
    guard useSerifDesign,
          let descriptor = base.fontDescriptor.withDesign(.serif),
          let font = NSFont(descriptor: descriptor, size: size) else {
        return base
    }
    return font
}

private struct NativeSelectableTextRepresentable: NSViewRepresentable {
    let model: NativeTextRenderModel
    let selectedRange: NativeTextSelectionRequest?
    let scrollTargetOffset: Int?
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
            context.coordinator.selectionDebouncer.cancel()
            context.coordinator.programmaticChange = true
            textView.setSelectedRange(NSRange(location: NSNotFound, length: 0))
            context.coordinator.programmaticChange = false
            context.coordinator.appliedSelection = nil
        } else if let selectedRange,
                  context.coordinator.appliedSelection != selectedRange {
            context.coordinator.selectionDebouncer.cancel()
            let range = clampedNSRange(for: selectedRange, textLength: model.text.utf16.count)
            context.coordinator.programmaticChange = true
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            context.coordinator.programmaticChange = false
            context.coordinator.appliedSelection = selectedRange
        } else if let scrollTargetOffset,
                  context.coordinator.appliedScrollTarget != scrollTargetOffset {
            let location = max(0, min(scrollTargetOffset, model.text.utf16.count))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            context.coordinator.appliedScrollTarget = scrollTargetOffset
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: NativeTextRenderModel?
        var programmaticChange = false
        var appliedSelection: NativeTextSelectionRequest?
        var appliedScrollTarget: Int?
        let onSelectionChange: (Range<Int>?) -> Void
        let selectionDebouncer = SelectionChangeDebouncer()

        init(onSelectionChange: @escaping (Range<Int>?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !programmaticChange,
                  let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            let range: Range<Int>? =
                if selection.location != NSNotFound, selection.length > 0 {
                    selection.location..<(selection.location + selection.length)
                } else {
                    nil
                }
            selectionDebouncer.submit(range, deliver: onSelectionChange)
        }
    }
}
#endif

private func clampedNSRange(
    for request: NativeTextSelectionRequest,
    textLength: Int
) -> NSRange {
    let lower = max(0, min(request.startUTF16, textLength))
    let upper = max(lower, min(request.endUTF16, textLength))
    return NSRange(location: lower, length: upper - lower)
}

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

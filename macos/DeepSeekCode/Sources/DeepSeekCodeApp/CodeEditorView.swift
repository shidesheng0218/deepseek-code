import AppKit
import SwiftUI
import DeepSeekCodeCore

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onSave: () -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = CodeTextView(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(WorkspaceDesignTokens.editorFontSize), weight: .regular)
        textView.textColor = AppTheme.text.nsColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 56, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.onSave = onSave
        textView.onClose = onClose
        textView.string = text
        textView.rebuildLineIndex()

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        textView.onSave = onSave
        textView.onClose = onClose
        if textView.string != text {
            context.coordinator.isSynchronizing = true
            textView.string = text
            textView.rebuildLineIndex()
            context.coordinator.isSynchronizing = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: CodeTextView?
        var isSynchronizing = false
        private var pendingUpdate: DispatchWorkItem?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing, let textView else { return }
            textView.rebuildLineIndex()
            pendingUpdate?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.text = textView.string
            }
            pendingUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }
}

final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    private var lineStartIndices: [Int] = [0]

    override var acceptsFirstResponder: Bool { true }

    func rebuildLineIndex() {
        let source = string as NSString
        guard source.length > 0 else {
            lineStartIndices = [0]
            return
        }
        var indices: [Int] = [0]
        indices.reserveCapacity(max(2, source.length / 24))
        var index = 0
        while index < source.length {
            if source.character(at: index) == 10 {
                indices.append(index + 1)
            }
            index += 1
        }
        if indices.last != source.length {
            indices.append(source.length)
        }
        lineStartIndices = indices
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "s":
                onSave?()
                return true
            case "w":
                onClose?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawLineNumbers()
    }

    private func drawLineNumbers() {
        guard let layoutManager, let textContainer else { return }
        let visibleRect = enclosingScrollView?.contentView.bounds ?? bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: AppTheme.secondaryText.nsColor,
            .paragraphStyle: paragraphStyle
        ]
        let selectedLine = lineNumber(for: selectedRange().location)
        let gutterWidth: CGFloat = 44

        let gutterRect = NSRect(x: 0, y: visibleRect.minY, width: gutterWidth, height: visibleRect.height)
        NSColor.windowBackgroundColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(rect: gutterRect).fill()
        AppTheme.border.nsColor.withAlphaComponent(0.3).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: gutterWidth - 0.5, y: visibleRect.minY))
        divider.line(to: NSPoint(x: gutterWidth - 0.5, y: visibleRect.maxY))
        divider.lineWidth = 1
        divider.stroke()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, usedRect, _, glyphs, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphs.location)
            let lineNumber = self.lineNumber(for: charIndex)
            let numberString = "\(lineNumber)" as NSString
            let numberSize = numberString.size(withAttributes: attributes)
            let y = lineFragmentRect.minY + (lineFragmentRect.height - numberSize.height) / 2
            let rect = NSRect(x: 4, y: y, width: gutterWidth - 10, height: numberSize.height)
            if lineNumber == selectedLine {
                AppTheme.secondaryText.nsColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: lineFragmentRect.minY, width: gutterWidth - 4, height: lineFragmentRect.height), xRadius: 5, yRadius: 5).fill()
            }
            numberString.draw(in: rect, withAttributes: attributes)
            _ = usedRect
        }
    }

    private func lineNumber(for characterIndex: Int) -> Int {
        guard characterIndex > 0 else { return 1 }
        guard lineStartIndices.count > 1 else { return 1 }
        var lower = 0
        var upper = lineStartIndices.count - 1
        while lower < upper {
            let mid = (lower + upper + 1) / 2
            if lineStartIndices[mid] <= characterIndex {
                lower = mid
            } else {
                upper = mid - 1
            }
        }
        return lower + 1
    }
}

private extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

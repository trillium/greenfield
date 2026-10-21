import SwiftUI
import UIKit

/// Lays text out like the stock text view and draws a return glyph at every line break. Only the drawing is added: the characters,
/// the selection and the copy and paste of the text are untouched, so the glyph can never end up in what is sent.
final class MarkerLayoutManager: NSLayoutManager {
    var markerColor = UIColor.secondaryLabel
    /// Draws one marker. Replaceable so a test can see what would be drawn; `index` is the line break's character offset.
    var markerDrawer: ((_ index: Int, _ glyph: String, _ attributes: [NSAttributedString.Key: Any], _ point: CGPoint) -> Void)?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        for index in DictationText.lineBreakOffsets(in: storage.string) where NSLocationInRange(index, visible) && index < text.length {
            let glyph = glyphIndexForCharacter(at: index)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markerColor]
            // The glyph sits on the line's baseline, right after the last character before the break.
            let point = CGPoint(x: origin.x + line.minX + position.x, y: origin.y + line.minY + position.y - font.ascender)
            if let markerDrawer {
                markerDrawer(index, DictationText.marker, attributes, point)
            } else {
                (DictationText.marker as NSString).draw(at: point, withAttributes: attributes)
            }
        }
    }
}

/// A multi-line text view with a visible return marker at each line break, read aloud as "new line".
final class MarkedTextView: UITextView {
    /// Room kept free at the right edge so the marker after a full line is never cut off.
    private static let markerRoom: CGFloat = 20

    let markerLayoutManager: MarkerLayoutManager
    private var excludedWidth: CGFloat = 0

    init(frame: CGRect) {
        let storage = NSTextStorage()
        let layout = MarkerLayoutManager()
        let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        markerLayoutManager = layout
        super.init(frame: frame, textContainer: container)
        font = UIFont.preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        autocorrectionType = .default
        accessibilityLabel = "Dictated text"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textContainer.size.width
        guard width > Self.markerRoom, width != excludedWidth else { return }
        excludedWidth = width
        let strip = CGRect(x: width - Self.markerRoom, y: 0, width: Self.markerRoom, height: 100_000)
        textContainer.exclusionPaths = [UIBezierPath(rect: strip)]
    }

    /// VoiceOver reads each line break as "new line". The text itself, and so the editing and the caret, is unchanged.
    override var accessibilityValue: String? {
        get { DictationText.spoken(text ?? "") }
        set {}
    }
}

/// The Dictate screen's text box: dictated words and typed text, with each line break shown as a return marker.
struct MarkedTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> MarkedTextView {
        let view = MarkedTextView(frame: .zero)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: MarkedTextView, context: Context) {
        context.coordinator.binding = $text
        guard view.text != text else { return }
        let selection = view.selectedRange
        view.text = text
        let length = (text as NSString).length
        // Dictation lands at the end; a cursor that was at the end stays there.
        view.selectedRange = selection.location >= length - 1 ? NSRange(location: length, length: 0)
            : NSRange(location: min(selection.location, length), length: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkedTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(fitted, 110), 260))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<String>

        init(text: Binding<String>) { binding = text }

        func textViewDidChange(_ textView: UITextView) {
            binding.wrappedValue = textView.text ?? ""
        }

        /// A paste or a keyboard can bring CRLF or a Unicode separator: it goes in as a plain line feed.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            let clean = DictationText.normalizingNewlines(replacement)
            guard clean != replacement else { return true }
            textView.textStorage.replaceCharacters(in: range, with: clean)
            textView.selectedRange = NSRange(location: range.location + (clean as NSString).length, length: 0)
            textViewDidChange(textView)
            return false
        }
    }
}

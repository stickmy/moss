import AppKit
import SwiftUI

/// A scroll view that uses ThemedOverlayScroller for themed scrollbar appearance.
/// Content is hosted via NSHostingView inside an NSScrollView.
struct ThemedScrollView<Content: View>: NSViewRepresentable {
    let theme: MossTheme
    var scrollToOffset: CGFloat = 0
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> _ScrollContainer<Content> {
        _ScrollContainer(content: content, theme: theme)
    }

    func updateNSView(_ container: _ScrollContainer<Content>, context: Context) {
        container.update(content: content, theme: theme, scrollToOffset: scrollToOffset)
    }
}

@MainActor
final class _ScrollContainer<Content: View>: NSView {
    private let scrollView = NSScrollView()
    private let hostingView: NSHostingView<Content>

    init(content: Content, theme: MossTheme) {
        hostingView = NSHostingView(rootView: content)
        super.init(frame: .zero)

        let clipView = _FlippedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.verticalScroller = ThemedOverlayScroller()
        scrollView.documentView = hostingView

        addSubview(scrollView)

        (scrollView.verticalScroller as? ThemedOverlayScroller)?.applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocumentView()
    }

    func update(content: Content, theme: MossTheme, scrollToOffset: CGFloat) {
        hostingView.rootView = content
        (scrollView.verticalScroller as? ThemedOverlayScroller)?.applyTheme(theme)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeDocumentView()

            let docHeight = self.hostingView.frame.height
            let clipHeight = self.scrollView.contentView.bounds.height
            guard docHeight > clipHeight else { return }
            let maxY = docHeight - clipHeight
            let y = min(max(0, scrollToOffset), maxY)
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    private func sizeDocumentView() {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        hostingView.frame.size.width = width
        let fitting = hostingView.fittingSize
        hostingView.frame.size.height = fitting.height
    }
}

private final class _FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

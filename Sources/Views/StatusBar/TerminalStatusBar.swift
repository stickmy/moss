import AppKit
import SwiftUI

struct TaskProgressIndicator: View {
    let tasks: [TrackedTask]
    @Environment(\.mossTheme) private var theme
    @State private var showDropdown = false

    private var completedCount: Int { tasks.filter(\.isDone).count }
    private var currentTask: TrackedTask? { tasks.first(where: { !$0.isDone }) }

    var body: some View {
        Button {
            showDropdown.toggle()
        } label: {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(tasks) { task in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(task.isDone ? Color.green : theme.secondaryForeground.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Text("\(completedCount)/\(tasks.count)")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForeground)
                    .monospacedDigit()

                if let currentTask {
                    Text(currentTask.subject)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .buttonStyle(.plain)
        .background(
            TaskListDropdownAnchor(
                isPresented: $showDropdown,
                tasks: tasks,
                theme: theme
            )
        )
    }
}

// MARK: - Custom Dropdown (Pure AppKit)

private struct TaskListDropdownAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let tasks: [TrackedTask]
    let theme: MossTheme

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            context.coordinator.show(
                relativeTo: nsView,
                tasks: tasks,
                theme: theme,
                onDismiss: { isPresented = false }
            )
        } else {
            context.coordinator.dismiss()
        }
    }

    final class Coordinator {
        private var panel: NSPanel?
        private var clickMonitor: EventMonitor?
        private var keyMonitor: EventMonitor?
        private var dismissAction: (() -> Void)?

        func show(
            relativeTo anchor: NSView,
            tasks: [TrackedTask],
            theme: MossTheme,
            onDismiss: @escaping () -> Void
        ) {
            guard panel == nil, let window = anchor.window else { return }
            dismissAction = onDismiss

            let bgColor = NSColor(theme.background)
            let fgColor = NSColor(theme.foreground)
            let dimColor = NSColor(theme.secondaryForeground)
            let cornerRadius: CGFloat = 4
            let shadowInset: CGFloat = 4

            // Build content
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

            for task in tasks {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6

                let icon = NSImageView()
                let symbolName = task.isDone ? "checkmark.square.fill" : "square"
                icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                icon.contentTintColor = task.isDone ? .systemGreen : dimColor
                icon.setContentHuggingPriority(.required, for: .horizontal)
                icon.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 14),
                    icon.heightAnchor.constraint(equalToConstant: 14),
                ])

                let label = NSTextField(labelWithString: task.subject)
                label.font = .systemFont(ofSize: 11)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1

                if task.isDone {
                    label.attributedStringValue = NSAttributedString(
                        string: task.subject,
                        attributes: [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: dimColor,
                        ]
                    )
                } else {
                    label.textColor = fgColor
                }

                row.addArrangedSubview(icon)
                row.addArrangedSubview(label)
                stack.addArrangedSubview(row)
            }

            let fittingSize = stack.fittingSize
            let contentSize = NSSize(
                width: max(180, min(320, fittingSize.width)),
                height: fittingSize.height
            )
            let panelSize = NSSize(
                width: contentSize.width + shadowInset * 2,
                height: contentSize.height + shadowInset * 2
            )

            // Position below anchor
            let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
            let anchorOnScreen = window.convertToScreen(anchorInWindow)
            let origin = CGPoint(
                x: anchorOnScreen.minX - shadowInset,
                y: anchorOnScreen.minY - contentSize.height - 4 - shadowInset
            )

            let p = NSPanel(
                contentRect: CGRect(origin: origin, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.hidesOnDeactivate = false

            let rootView = NSView(frame: NSRect(origin: .zero, size: panelSize))
            rootView.wantsLayer = true
            rootView.layer?.backgroundColor = NSColor.clear.cgColor

            let shadowView = NSView(
                frame: NSRect(
                    x: shadowInset,
                    y: shadowInset,
                    width: contentSize.width,
                    height: contentSize.height
                )
            )
            shadowView.wantsLayer = true
            shadowView.layer?.shadowColor = NSColor.black.cgColor
            shadowView.layer?.shadowOpacity = 0.06
            shadowView.layer?.shadowRadius = 4
            shadowView.layer?.shadowOffset = CGSize(width: 0, height: -1)
            shadowView.layer?.shadowPath = CGPath(
                roundedRect: shadowView.bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            let container = NSView(frame: shadowView.bounds)
            container.wantsLayer = true
            container.layer?.backgroundColor = bgColor.cgColor
            container.layer?.cornerRadius = cornerRadius
            container.layer?.masksToBounds = true

            stack.frame = container.bounds
            stack.autoresizingMask = [.width, .height]
            container.addSubview(stack)

            shadowView.addSubview(container)
            rootView.addSubview(shadowView)

            p.contentView = rootView
            p.orderFront(nil)
            self.panel = p

            clickMonitor = EventMonitor([.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                if event.window !== panel {
                    DispatchQueue.main.async { self.requestDismiss() }
                }
                return event
            }

            keyMonitor = EventMonitor(.keyDown) { [weak self] event in
                guard let self, self.panel != nil else { return event }
                guard event.keyCode == 53 else { return event }

                DispatchQueue.main.async { self.requestDismiss() }
                return nil
            }
        }

        func dismiss() {
            clickMonitor = nil
            keyMonitor = nil
            panel?.orderOut(nil)
            panel = nil
            dismissAction = nil
        }

        deinit {
            // EventMonitor handles its own cleanup in deinit,
            // but we still need to dismiss the panel.
            panel?.orderOut(nil)
        }

        private func requestDismiss() {
            guard panel != nil else { return }
            let dismissAction = self.dismissAction
            dismiss()
            dismissAction?()
        }
    }
}

import SwiftUI
import GhosttyKit

struct TerminalSearchOverlay: View {
    @Bindable var searchState: TerminalSearchState
    let onNavigate: (_ direction: String) -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.mossTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $searchState.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 180)
                .padding(.leading, 8)
                .padding(.trailing, matchCountWidth)
                .padding(.vertical, 6)
                .background(theme.background.opacity(0.6))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                )
                .focused($isSearchFieldFocused)
                .overlay(alignment: .trailing) {
                    matchCountLabel
                        .padding(.trailing, 8)
                }
                .onSubmit {
                    onNavigate("next")
                }
                .onExitCommand {
                    onClose()
                }

            Button(action: { onNavigate("previous") }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(SearchNavButtonStyle(theme: theme))

            Button(action: { onNavigate("next") }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(SearchNavButtonStyle(theme: theme))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(SearchNavButtonStyle(theme: theme))
        }
        .padding(8)
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 4)
        .padding(8)
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: searchState.focusToken) {
            isSearchFieldFocused = true
        }
    }

    private var matchCountWidth: CGFloat { 50 }

    @ViewBuilder
    private var matchCountLabel: some View {
        if let total = searchState.total {
            if let selected = searchState.selected {
                Text("\(selected + 1)/\(total)")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForeground)
                    .monospacedDigit()
            } else {
                Text("-/\(total)")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryForeground)
                    .monospacedDigit()
            }
        }
    }
}

private struct SearchNavButtonStyle: ButtonStyle {
    let theme: MossTheme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed
                ? theme.foreground
                : theme.secondaryForeground)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? theme.hoverBackground : .clear)
            )
            .onHover { isHovered = $0 }
    }
}

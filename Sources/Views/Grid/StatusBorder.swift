import SwiftUI

struct StatusBorder: View {
    let status: TerminalStatus

    var body: some View {
        Group {
            switch status {
            case .pending:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange, lineWidth: 3)
            case .none:
                EmptyView()
            }
        }
        .id(status.rawValue)
    }
}

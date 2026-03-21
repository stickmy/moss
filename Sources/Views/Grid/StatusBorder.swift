import SwiftUI

struct StatusBorder: View {
    let status: TerminalStatus
    @State private var rotation: Double = 0

    var body: some View {
        switch status {
        case .running:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    AngularGradient(
                        colors: [.blue, .cyan, .blue.opacity(0.3), .blue],
                        center: .center,
                        angle: .degrees(rotation)
                    ),
                    lineWidth: 1
                )
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
        case .pending:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange, lineWidth: 3)
        case .none:
            EmptyView()
        }
    }
}

import SwiftUI

struct TerminalCanvasGridBackground: View {
    let viewport: TerminalCanvasViewport
    let size: CGSize

    @Environment(\.mossTheme) private var theme

    var body: some View {
        Canvas { context, canvasSize in
            let logicalMinX = viewport.offset.x - canvasSize.width / (2 * max(viewport.scale, 0.1))
            let logicalMaxX = viewport.offset.x + canvasSize.width / (2 * max(viewport.scale, 0.1))
            let logicalMinY = viewport.offset.y - canvasSize.height / (2 * max(viewport.scale, 0.1))
            let logicalMaxY = viewport.offset.y + canvasSize.height / (2 * max(viewport.scale, 0.1))

            let minorStep = TerminalCanvasMetrics.gridStep
            let majorStep = minorStep * 4

            var minorPath = Path()
            var majorPath = Path()

            var x = floor(logicalMinX / minorStep) * minorStep
            while x <= logicalMaxX {
                let screenX = (x - viewport.offset.x) * viewport.scale + canvasSize.width / 2
                if isMajorLine(x, majorStep: majorStep) {
                    majorPath.move(to: CGPoint(x: screenX, y: 0))
                    majorPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                } else {
                    minorPath.move(to: CGPoint(x: screenX, y: 0))
                    minorPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                }
                x += minorStep
            }

            var y = floor(logicalMinY / minorStep) * minorStep
            while y <= logicalMaxY {
                let screenY = (y - viewport.offset.y) * viewport.scale + canvasSize.height / 2
                if isMajorLine(y, majorStep: majorStep) {
                    majorPath.move(to: CGPoint(x: 0, y: screenY))
                    majorPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                } else {
                    minorPath.move(to: CGPoint(x: 0, y: screenY))
                    minorPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                }
                y += minorStep
            }

            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .color(theme.background)
            )
            context.stroke(
                minorPath,
                with: .color(theme.border.opacity(0.08)),
                lineWidth: 1
            )
            context.stroke(
                majorPath,
                with: .color(theme.border.opacity(0.22)),
                lineWidth: 1
            )
        }
        .frame(width: size.width, height: size.height)
    }

    private func isMajorLine(_ value: CGFloat, majorStep: CGFloat) -> Bool {
        let remainder = abs(value.truncatingRemainder(dividingBy: majorStep))
        return remainder < 0.5 || abs(remainder - majorStep) < 0.5
    }
}

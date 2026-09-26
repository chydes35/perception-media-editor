import SwiftUI

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            draw(channel: data.red, color: .red, in: &context, size: size)
            draw(channel: data.green, color: .green, in: &context, size: size)
            draw(channel: data.blue, color: .blue, in: &context, size: size)
        }
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08))
        }
        .accessibilityLabel("RGB histogram")
        .accessibilityValue(data.hasValues ? "Histogram available" : "No photo selected")
    }

    private func draw(
        channel: [Double],
        color: Color,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard channel.count > 1 else { return }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))

        for (index, value) in channel.enumerated() {
            let x = CGFloat(index) / CGFloat(channel.count - 1) * size.width
            let y = size.height - CGFloat(value) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.34)))
        context.stroke(path, with: .color(color.opacity(0.78)), lineWidth: 0.7)
    }
}

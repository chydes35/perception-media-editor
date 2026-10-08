import SwiftUI

/// Captures one click on the fitted, edited photo and shows where the neutral sample will land.
/// The surrounding photo workspace can still receive mouse-wheel zoom while this layer is open.
struct WhiteBalancePickingLayer: View {
    @EnvironmentObject private var store: EditorStore
    let imageSize: CGSize
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { view in
            let frame = MaskEditingLayer.fittedFrame(in: view.size, image: imageSize)
            ZStack {
                Canvas { context, _ in
                    guard let hover, frame.contains(hover) else { return }
                    let ring = Path(ellipseIn: CGRect(x: hover.x - 9, y: hover.y - 9,
                                                       width: 18, height: 18))
                    context.stroke(ring, with: .color(.black.opacity(0.8)), lineWidth: 3)
                    context.stroke(ring, with: .color(.white), lineWidth: 1.5)
                    var cross = Path()
                    cross.move(to: CGPoint(x: hover.x - 14, y: hover.y))
                    cross.addLine(to: CGPoint(x: hover.x + 14, y: hover.y))
                    cross.move(to: CGPoint(x: hover.x, y: hover.y - 14))
                    cross.addLine(to: CGPoint(x: hover.x, y: hover.y + 14))
                    context.stroke(cross, with: .color(.white), lineWidth: 1)
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let point = PhotoComparisonView.normalizedPoint(
                            location, in: view.size, image: imageSize
                        ) else { return }
                        store.pickWhiteBalance(at: NormalizedPoint(point))
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hover = location
                        case .ended: hover = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("White balance eyedropper. Click a neutral gray or white part of the photo.")
    }
}

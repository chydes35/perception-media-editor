import AppKit
import SwiftUI

/// The picker operates in the displayed photo's coordinates; the store maps through crop and
/// rotation before looking up Vision's instance label in the source image.
struct SubjectPickingLayer: View {
    @EnvironmentObject private var store: EditorStore
    let imageSize: CGSize
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { view in
            let frame = MaskEditingLayer.fittedFrame(in: view.size, image: imageSize)
            ZStack {
                Canvas { context, _ in
                    if store.isClickSelecting, let geometry = store.currentGeometry {
                        for click in store.clickPoints {
                            let point = geometry.finished(fromSource: NormalizedPoint(x: click.x, y: click.y))
                            let center = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
                            let dot = Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                            context.fill(dot, with: .color(click.include ? .green : .red))
                            context.stroke(dot, with: .color(.white), lineWidth: 2)
                            context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 0.75)
                            if !click.include {
                                var bar = Path()
                                bar.move(to: CGPoint(x: center.x - 3, y: center.y))
                                bar.addLine(to: CGPoint(x: center.x + 3, y: center.y))
                                context.stroke(bar, with: .color(.white), lineWidth: 2)
                            }
                        }
                    }
                    guard let hover, frame.contains(hover) else { return }
                    let ring = Path(ellipseIn: CGRect(x: hover.x - 10, y: hover.y - 10, width: 20, height: 20))
                    context.stroke(ring, with: .color(.black.opacity(0.8)), lineWidth: 3)
                    context.stroke(ring, with: .color(.orange), lineWidth: 1.5)
                }
                .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let point = PhotoComparisonView.normalizedPoint(
                            location, in: view.size, image: imageSize
                        ) else { return }
                        if store.isClickSelecting {
                            store.clickSelect(at: NormalizedPoint(point), include: !NSEvent.modifierFlags.contains(.option))
                        } else {
                            store.pickSubject(at: NormalizedPoint(point))
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hover = location
                            let point = PhotoComparisonView.normalizedPoint(
                                location, in: view.size, image: imageSize
                            )
                            if !store.isClickSelecting { store.previewSubject(at: point.map { NormalizedPoint($0) }) }
                        case .ended:
                            hover = nil
                            if !store.isClickSelecting { store.previewSubject(at: nil) }
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.isClickSelecting
            ? "Click to select. Click what to select; option-click removes a part."
            : "Subject picker. Hover to preview a subject, then click to select it.")
    }
}

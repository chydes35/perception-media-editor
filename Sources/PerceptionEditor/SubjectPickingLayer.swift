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

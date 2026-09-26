import AppKit
import SwiftUI

/// On-photo brush, repair locations, and draggable source pin.
struct RetouchEditingLayer: View {
    @EnvironmentObject private var store: EditorStore
    let imageSize: CGSize

    private enum DragState {
        case painting
        case movingSource(UUID)
        case pickingSource
        case ignored
    }

    @State private var drag: DragState?
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { view in
            let frame = MaskEditingLayer.fittedFrame(in: view.size, image: imageSize)
            ZStack {
                Canvas { context, _ in draw(&context, frame: frame) }
                    .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in changed(value, frame: frame) }
                            .onEnded { _ in ended() }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover = point
                        case .ended: hover = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heal and clone editing area")
    }

    private func viewPoint(_ source: NormalizedPoint, _ geometry: ImageGeometry, _ frame: CGRect) -> CGPoint {
        let point = geometry.finished(fromSource: source)
        return CGPoint(x: frame.minX + point.x * frame.width,
                       y: frame.minY + point.y * frame.height)
    }

    private func sourcePoint(_ point: CGPoint, _ geometry: ImageGeometry, _ frame: CGRect) -> NormalizedPoint {
        geometry.source(fromFinished: NormalizedPoint(
            x: (point.x - frame.minX) / max(1, frame.width),
            y: (point.y - frame.minY) / max(1, frame.height)
        ))
    }

    private func draw(_ context: inout GraphicsContext, frame: CGRect) {
        guard let geometry = store.currentGeometry, frame.width > 0 else { return }
        context.clip(to: Path(frame))
        for stroke in store.retouches {
            guard let first = stroke.target else { continue }
            let point = viewPoint(first, geometry, frame)
            let selected = stroke.id == store.selectedRetouchID
            let color: Color = stroke.kind == .heal ? .mint : .orange
            let ring = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            context.fill(ring, with: .color(color.opacity(stroke.isEnabled ? 0.85 : 0.3)))
            context.stroke(ring, with: .color(.white.opacity(selected ? 1 : 0.6)), lineWidth: selected ? 1.5 : 0.8)
            if selected {
                let sample = viewPoint(stroke.source, geometry, frame)
                var connector = Path()
                connector.move(to: point)
                connector.addLine(to: sample)
                context.stroke(connector, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let pin = Path(ellipseIn: CGRect(x: sample.x - 7, y: sample.y - 7, width: 14, height: 14))
                context.fill(pin, with: .color(.black.opacity(0.65)))
                context.stroke(pin, with: .color(color), lineWidth: 2)
            }
        }

        if let cloneSource = store.cloneSource, store.retouchTool == .clone {
            let point = viewPoint(cloneSource, geometry, frame)
            let pin = Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
            context.stroke(pin, with: .color(.orange), lineWidth: 2)
            var cross = Path()
            cross.move(to: CGPoint(x: point.x - 4, y: point.y)); cross.addLine(to: CGPoint(x: point.x + 4, y: point.y))
            cross.move(to: CGPoint(x: point.x, y: point.y - 4)); cross.addLine(to: CGPoint(x: point.x, y: point.y + 4))
            context.stroke(cross, with: .color(.orange), lineWidth: 1)
        }

        if store.retouchTool != nil, let hover, frame.contains(hover) {
            let radius = CGFloat(store.retouchSize) * geometry.longSide * frame.width / max(1, geometry.finishedSize.width) / 2
            let ring = Path(ellipseIn: CGRect(x: hover.x - radius, y: hover.y - radius,
                                               width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.black.opacity(0.8)), lineWidth: 2.5)
            context.stroke(ring, with: .color(.white), lineWidth: 1)
        }
    }

    private func changed(_ value: DragGesture.Value, frame: CGRect) {
        guard let geometry = store.currentGeometry, frame.width > 0 else { return }
        let point = sourcePoint(value.location, geometry, frame)
        if drag == nil {
            guard frame.contains(value.startLocation) else { drag = .ignored; return }
            if let selected = store.selectedRetouch {
                let pin = viewPoint(selected.source, geometry, frame)
                if hypot(pin.x - value.startLocation.x, pin.y - value.startLocation.y) < 14 {
                    store.beginAdjustmentEdit()
                    store.nextHistoryLabel = "Move repair source"
                    drag = .movingSource(selected.id)
                }
            }
            if drag == nil {
                if store.retouchPickingSource || (store.retouchTool == .clone && NSEvent.modifierFlags.contains(.option)) {
                    store.setCloneSource(sourcePoint(value.startLocation, geometry, frame))
                    drag = .pickingSource
                } else if store.retouchTool != nil {
                    store.beginRetouch(at: sourcePoint(value.startLocation, geometry, frame))
                    drag = store.selectedRetouch != nil ? .painting : .ignored
                } else {
                    if let hit = store.retouches.reversed().first(where: { stroke in
                        guard let target = stroke.target else { return false }
                        let marker = viewPoint(target, geometry, frame)
                        return hypot(marker.x - value.startLocation.x, marker.y - value.startLocation.y) < 12
                    }) {
                        store.selectRetouch(hit.id)
                    }
                    drag = .ignored
                }
            }
        }
        switch drag {
        case .painting:
            store.extendRetouch(to: point)
        case .movingSource(let id):
            store.moveRetouchSource(id, to: point)
        case .pickingSource:
            store.setCloneSource(point)
        case .ignored, .none:
            break
        }
    }

    private func ended() {
        switch drag {
        case .painting: store.endRetouchStroke()
        case .movingSource: store.endAdjustmentEdit()
        case .pickingSource, .ignored, .none: break
        }
        drag = nil
    }
}

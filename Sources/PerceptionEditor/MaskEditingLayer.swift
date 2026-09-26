import AppKit
import SwiftUI

/// Draws the selected mask's handles over the photo and turns drags into mask edits.
///
/// Everything here works in two spaces: the finished picture as it is drawn (rotated,
/// straightened, and cropped), and the original photo, where masks are stored.
/// `ImageGeometry` converts between them.
struct MaskEditingLayer: View {
    @EnvironmentObject private var store: EditorStore
    /// Size of the preview image being shown; only its shape matters.
    let imageSize: CGSize

    private enum Drag {
        case creatingLinear(UUID)
        case creatingRadial(UUID, center: NormalizedPoint)
        case painting
        case movingLinearStart(UUID)
        case movingLinearEnd(UUID)
        case movingLinear(UUID, start: NormalizedPoint, end: NormalizedPoint, grabbed: NormalizedPoint)
        case movingRadial(UUID, grabOffset: CGVector)
        case resizingRadial(UUID, axis: Axis)
    }

    private enum Axis { case x, y }

    @State private var drag: Drag?
    @State private var hover: CGPoint?

    private let handleRadius: CGFloat = 7
    private let hitRadius: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fittedFrame(in: geometry.size, image: imageSize)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, frame: frame)
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in dragChanged(value, frame: frame) }
                            .onEnded { value in dragEnded(value, frame: frame) }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hover = location
                        case .ended: hover = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mask editing area")
    }

    // MARK: Space conversion

    /// Where the fitted picture sits inside the view (matches the padded fit of the preview).
    static func fittedFrame(in view: CGSize, image: CGSize, padding: CGFloat = 28) -> CGRect {
        let available = CGSize(width: view.width - padding * 2, height: view.height - padding * 2)
        guard available.width > 0, available.height > 0, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func viewPoint(_ source: NormalizedPoint, _ geometry: ImageGeometry, _ frame: CGRect) -> CGPoint {
        let finished = geometry.finished(fromSource: source)
        return CGPoint(x: frame.minX + finished.x * frame.width, y: frame.minY + finished.y * frame.height)
    }

    private func sourcePoint(_ view: CGPoint, _ geometry: ImageGeometry, _ frame: CGRect) -> NormalizedPoint {
        geometry.source(fromFinished: NormalizedPoint(
            x: (view.x - frame.minX) / max(1, frame.width),
            y: (view.y - frame.minY) / max(1, frame.height)
        ))
    }

    /// Finished-picture pixels to view points.
    private func pointsPerPixel(_ geometry: ImageGeometry, _ frame: CGRect) -> CGFloat {
        frame.width / max(1, geometry.finishedSize.width)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, frame: CGRect) {
        guard let geometry = store.currentGeometry else { return }
        let accent = Color.orange

        if let mask = store.selectedMask {
            switch mask.shape {
            case .linear(let start, let end):
                drawLinear(&context, start, end, geometry, frame, accent)
            case .radial(let center, let rx, let ry, let rotation, let feather):
                drawRadial(&context, center, rx, ry, rotation, feather, geometry, frame, accent)
            case .brush:
                break
            }
        }

        if store.maskTool == .brush, let hover, frame.contains(hover) {
            let radius = CGFloat(store.brushSize) * geometry.longSide * pointsPerPixel(geometry, frame) / 2
            let ring = Path(ellipseIn: CGRect(x: hover.x - radius, y: hover.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 2.5)
            context.stroke(ring, with: .color(store.brushErasing ? .red : .white), lineWidth: 1.2)
            if store.brushFeather > 0.02 {
                let inner = radius * CGFloat(1 - store.brushFeather)
                let dashed = Path(ellipseIn: CGRect(x: hover.x - inner, y: hover.y - inner, width: inner * 2, height: inner * 2))
                context.stroke(dashed, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
        }
    }

    private func drawLinear(
        _ context: inout GraphicsContext, _ start: NormalizedPoint, _ end: NormalizedPoint,
        _ geometry: ImageGeometry, _ frame: CGRect, _ color: Color
    ) {
        let a = viewPoint(start, geometry, frame), b = viewPoint(end, geometry, frame)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let reach = max(frame.width, frame.height)
        let perpendicular = CGVector(dx: -dy / length * reach, dy: dx / length * reach)

        func line(through point: CGPoint) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: point.x - perpendicular.dx, y: point.y - perpendicular.dy))
            path.addLine(to: CGPoint(x: point.x + perpendicular.dx, y: point.y + perpendicular.dy))
            return path
        }
        context.clip(to: Path(frame))
        context.stroke(line(through: a), with: .color(color), lineWidth: 1.4)
        context.stroke(line(through: b), with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        var axis = Path(); axis.move(to: a); axis.addLine(to: b)
        context.stroke(axis, with: .color(color.opacity(0.7)), lineWidth: 1)
        drawHandle(&context, a, color)
        drawHandle(&context, b, color)
    }

    private func drawRadial(
        _ context: inout GraphicsContext, _ center: NormalizedPoint, _ rx: Double, _ ry: Double,
        _ rotation: Double, _ feather: Double, _ geometry: ImageGeometry, _ frame: CGRect, _ color: Color
    ) {
        func outline(scale: Double) -> Path {
            var path = Path()
            for step in 0 ... 72 {
                let point = radialPoint(center, rx * scale, ry * scale, rotation, angle: Double(step) / 72 * 2 * .pi, geometry)
                let mapped = viewPoint(point, geometry, frame)
                if step == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
            }
            path.closeSubpath()
            return path
        }
        context.clip(to: Path(frame))
        context.stroke(outline(scale: 1), with: .color(color), lineWidth: 1.4)
        if feather > 0.02 {
            context.stroke(outline(scale: max(0.05, 1 - feather)), with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        drawHandle(&context, viewPoint(center, geometry, frame), color)
        for handle in [radialHandle(center, rx, ry, rotation, .x, geometry), radialHandle(center, rx, ry, rotation, .y, geometry)] {
            drawHandle(&context, viewPoint(handle, geometry, frame), color, filled: false)
        }
    }

    private func drawHandle(_ context: inout GraphicsContext, _ point: CGPoint, _ color: Color, filled: Bool = true) {
        let rect = CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
        let circle = Path(ellipseIn: rect)
        context.fill(circle, with: .color(filled ? color : .black.opacity(0.55)))
        context.stroke(circle, with: .color(.white), lineWidth: 1.6)
    }

    // MARK: Radial geometry (in original-image pixels)

    /// A point on the ellipse, as a position in the original image.
    private func radialPoint(
        _ center: NormalizedPoint, _ rx: Double, _ ry: Double, _ rotation: Double, angle: Double, _ geometry: ImageGeometry
    ) -> NormalizedPoint {
        let long = Double(geometry.longSide)
        let cosine: Double = cos(angle), sine: Double = sin(angle)
        let local = CGPoint(x: CGFloat(rx * long * cosine), y: CGFloat(ry * long * sine))
        return offset(center, by: local, rotation: rotation, geometry)
    }

    private func radialHandle(
        _ center: NormalizedPoint, _ rx: Double, _ ry: Double, _ rotation: Double, _ axis: Axis, _ geometry: ImageGeometry
    ) -> NormalizedPoint {
        let long = Double(geometry.longSide)
        let local = axis == .x ? CGPoint(x: rx * long, y: 0) : CGPoint(x: 0, y: ry * long)
        return offset(center, by: local, rotation: rotation, geometry)
    }

    /// Moves `center` by `local` pixels in the ellipse's own frame, turned `rotation` degrees clockwise.
    private func offset(_ center: NormalizedPoint, by local: CGPoint, rotation: Double, _ geometry: ImageGeometry) -> NormalizedPoint {
        let turn: Double = rotation * Double.pi / 180
        let cosine: Double = cos(turn), sine: Double = sin(turn)
        let lx = Double(local.x), ly = Double(local.y)
        let x: Double = lx * cosine - ly * sine
        let y: Double = lx * sine + ly * cosine
        return NormalizedPoint(
            x: center.x + x / Double(geometry.sourceSize.width),
            y: center.y + y / Double(geometry.sourceSize.height)
        )
    }

    /// A position in the original as pixels from `center`, seen in the ellipse's own frame.
    private func localOffset(of point: NormalizedPoint, from center: NormalizedPoint, rotation: Double, _ geometry: ImageGeometry) -> CGPoint {
        let dx: Double = (point.x - center.x) * Double(geometry.sourceSize.width)
        let dy: Double = (point.y - center.y) * Double(geometry.sourceSize.height)
        let turn: Double = -rotation * Double.pi / 180
        let cosine: Double = cos(turn), sine: Double = sin(turn)
        return CGPoint(x: CGFloat(dx * cosine - dy * sine), y: CGFloat(dx * sine + dy * cosine))
    }

    // MARK: Gestures

    private func dragChanged(_ value: DragGesture.Value, frame: CGRect) {
        guard let geometry = store.currentGeometry else { return }
        let point = sourcePoint(value.location, geometry, frame)

        if drag == nil {
            drag = begin(at: value.startLocation, geometry: geometry, frame: frame)
        }
        guard let drag else { return }

        switch drag {
        case .creatingLinear(let id):
            store.updateMask(id) { $0.shape = .linear(start: startOfLinear($0), end: point) }
        case .creatingRadial(let id, let center):
            let radius = distanceInLongSides(from: center, to: point, geometry)
            store.updateMask(id) { mask in
                if case .radial(_, _, _, let rotation, let feather) = mask.shape {
                    mask.shape = .radial(center: center, radiusX: max(0.01, radius), radiusY: max(0.01, radius), rotation: rotation, feather: feather)
                }
            }
        case .painting:
            store.extendBrushStroke(to: point)
        case .movingLinearStart(let id):
            store.updateMask(id) { mask in
                if case .linear(_, let end) = mask.shape { mask.shape = .linear(start: point, end: end) }
            }
        case .movingLinearEnd(let id):
            store.updateMask(id) { mask in
                if case .linear(let start, _) = mask.shape { mask.shape = .linear(start: start, end: point) }
            }
        case .movingLinear(let id, let start, let end, let grabbed):
            let dx = point.x - grabbed.x, dy = point.y - grabbed.y
            store.updateMask(id) {
                $0.shape = .linear(
                    start: NormalizedPoint(x: start.x + dx, y: start.y + dy),
                    end: NormalizedPoint(x: end.x + dx, y: end.y + dy)
                )
            }
        case .movingRadial(let id, let grab):
            let moved = NormalizedPoint(x: point.x - Double(grab.dx), y: point.y - Double(grab.dy))
            store.updateMask(id) { mask in
                if case .radial(_, let rx, let ry, let rotation, let feather) = mask.shape {
                    mask.shape = .radial(center: moved, radiusX: rx, radiusY: ry, rotation: rotation, feather: feather)
                }
            }
        case .resizingRadial(let id, let axis):
            store.updateMask(id) { mask in
                guard case .radial(let center, let rx, let ry, let rotation, let feather) = mask.shape else { return }
                let local = localOffset(of: point, from: center, rotation: rotation, geometry)
                let long = Double(geometry.longSide)
                let radius = max(0.01, Double(axis == .x ? abs(local.x) : abs(local.y)) / long)
                mask.shape = .radial(
                    center: center,
                    radiusX: axis == .x ? radius : rx,
                    radiusY: axis == .y ? radius : ry,
                    rotation: rotation, feather: feather
                )
            }
        }
    }

    private func dragEnded(_ value: DragGesture.Value, frame: CGRect) {
        defer { drag = nil }
        guard let geometry = store.currentGeometry, let drag else { return }

        switch drag {
        case .painting:
            store.endBrushStroke()
        case .creatingLinear(let id):
            // A plain click, with no drag, makes a gradient a third of the picture tall.
            if hypot(value.translation.width, value.translation.height) < 4 {
                let start = sourcePoint(value.startLocation, geometry, frame)
                let end = sourcePoint(CGPoint(x: value.startLocation.x, y: value.startLocation.y + frame.height / 3), geometry, frame)
                store.updateMask(id) { $0.shape = .linear(start: start, end: end) }
            }
            store.endMaskDrag()
        case .creatingRadial(let id, let center):
            if hypot(value.translation.width, value.translation.height) < 4 {
                store.updateMask(id) {
                    $0.shape = .radial(center: center, radiusX: 0.15, radiusY: 0.15, rotation: 0, feather: 0.5)
                }
            }
            store.endMaskDrag()
        default:
            store.endMaskDrag(keepingTool: store.maskTool != .none)
        }
    }

    /// Decides what a drag that just began is doing.
    private func begin(at location: CGPoint, geometry: ImageGeometry, frame: CGRect) -> Drag? {
        let point = sourcePoint(location, geometry, frame)

        switch store.maskTool {
        case .linear:
            guard frame.contains(location), let id = store.beginGradient(.linear, at: point) else { return nil }
            return .creatingLinear(id)
        case .radial:
            guard frame.contains(location), let id = store.beginGradient(.radial, at: point) else { return nil }
            return .creatingRadial(id, center: point)
        case .brush:
            guard frame.contains(location) else { return nil }
            store.beginBrushStroke(at: point, erasing: NSEvent.modifierFlags.contains(.option))
            return store.isMaskInteracting ? .painting : nil
        case .none:
            return grab(at: location, geometry: geometry, frame: frame)
        }
    }

    /// With a mask selected, picks up whichever handle (or line) is under the pointer.
    private func grab(at location: CGPoint, geometry: ImageGeometry, frame: CGRect) -> Drag? {
        guard let mask = store.selectedMask else { return nil }
        let point = sourcePoint(location, geometry, frame)

        switch mask.shape {
        case .linear(let start, let end):
            let a = viewPoint(start, geometry, frame), b = viewPoint(end, geometry, frame)
            if hypot(location.x - a.x, location.y - a.y) <= hitRadius {
                store.beginMaskDrag(label: "Move gradient")
                return .movingLinearStart(mask.id)
            }
            if hypot(location.x - b.x, location.y - b.y) <= hitRadius {
                store.beginMaskDrag(label: "Move gradient")
                return .movingLinearEnd(mask.id)
            }
            if distance(from: location, toSegmentFrom: a, to: b) <= 9 {
                store.beginMaskDrag(label: "Move gradient")
                return .movingLinear(mask.id, start: start, end: end, grabbed: point)
            }
            return nil

        case .radial(let center, let rx, let ry, let rotation, _):
            let c = viewPoint(center, geometry, frame)
            let handleX = viewPoint(radialHandle(center, rx, ry, rotation, .x, geometry), geometry, frame)
            let handleY = viewPoint(radialHandle(center, rx, ry, rotation, .y, geometry), geometry, frame)
            if hypot(location.x - handleX.x, location.y - handleX.y) <= hitRadius {
                store.beginMaskDrag(label: "Resize gradient")
                return .resizingRadial(mask.id, axis: .x)
            }
            if hypot(location.x - handleY.x, location.y - handleY.y) <= hitRadius {
                store.beginMaskDrag(label: "Resize gradient")
                return .resizingRadial(mask.id, axis: .y)
            }
            if hypot(location.x - c.x, location.y - c.y) <= hitRadius * 1.6 {
                store.beginMaskDrag(label: "Move gradient")
                return .movingRadial(mask.id, grabOffset: CGVector(dx: point.x - center.x, dy: point.y - center.y))
            }
            return nil

        case .brush:
            return nil
        }
    }

    // MARK: Helpers

    private func startOfLinear(_ mask: LocalMask) -> NormalizedPoint {
        if case .linear(let start, _) = mask.shape { return start }
        return NormalizedPoint(x: 0.5, y: 0.5)
    }

    private func distanceInLongSides(from a: NormalizedPoint, to b: NormalizedPoint, _ geometry: ImageGeometry) -> Double {
        let dx = (b.x - a.x) * Double(geometry.sourceSize.width)
        let dy = (b.y - a.y) * Double(geometry.sourceSize.height)
        return hypot(dx, dy) / Double(geometry.longSide)
    }

    private func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

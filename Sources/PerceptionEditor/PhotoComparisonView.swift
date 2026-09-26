import AppKit
import SwiftUI

struct PhotoComparisonView: View {
    let original: NSImage?
    let edited: NSImage?
    let mode: PreviewMode
    let isCropping: Bool
    @Binding var cropRect: CGRect?
    let cropAspect: CropAspect
    /// Called with the clicked point (0–1 from the top-left of the photo) to open the 100% view.
    var onZoomRequest: ((CGPoint) -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)

            if let edited {
                switch mode {
                case .original:
                    fitted(original ?? edited)
                case .edited:
                    fitted(edited)
                case .split:
                    split(original: original ?? edited, edited: edited)
                case .sideBySide:
                    sideBySide(original: original ?? edited, edited: edited)
                }
            } else {
                ContentUnavailableView(
                    "Select a photo",
                    systemImage: "photo",
                    description: Text("Choose a photo in Library or import one to begin editing.")
                )
                .foregroundStyle(.white, .white.opacity(0.62))
            }

            if isCropping, mode == .edited {
                CropOverlayView(cropRect: $cropRect, aspect: cropAspect)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard !isCropping, mode == .edited, let edited,
                              let point = Self.normalizedPoint(location, in: geometry.size, image: edited.size)
                        else { return }
                        onZoomRequest?(point)
                    }
            }
            .allowsHitTesting(!isCropping && mode == .edited && onZoomRequest != nil)
        }
        .accessibilityHint("Click the photo to view it at 100 percent.")
    }

    /// Where a click landed on the fitted photo, as 0–1 from its top-left; nil outside the photo.
    nonisolated static func normalizedPoint(_ location: CGPoint, in viewSize: CGSize, image imageSize: CGSize) -> CGPoint? {
        let padding: CGFloat = 28
        let available = CGSize(width: viewSize.width - padding * 2, height: viewSize.height - padding * 2)
        guard available.width > 0, available.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - fitted.width) / 2, y: (viewSize.height - fitted.height) / 2)
        let x = (location.x - origin.x) / fitted.width
        let y = (location.y - origin.y) / fitted.height
        guard (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func fitted(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding(28)
    }

    private func split(original: NSImage, edited: NSImage) -> some View {
        GeometryReader { geometry in
            ZStack {
                fitted(original)
                fitted(edited)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geometry.size.width / 2)
                            Spacer(minLength: 0)
                        }
                    }

                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1)
                Text("ORIGINAL")
                    .comparisonLabel(alignment: .topLeading)
                Text("EDITED")
                    .comparisonLabel(alignment: .topTrailing)
            }
        }
    }

    private func sideBySide(original: NSImage, edited: NSImage) -> some View {
        HStack(spacing: 1) {
            ZStack(alignment: .topLeading) {
                Color.black
                fitted(original)
                Text("ORIGINAL").comparisonBadge()
            }
            ZStack(alignment: .topLeading) {
                Color.black
                fitted(edited)
                Text("EDITED").comparisonBadge()
            }
        }
    }
}

private struct CropOverlayView: View {
    @Binding var cropRect: CGRect?
    let aspect: CropAspect
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let rect = displayRect(for: geometry.size)

            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(pixelRect(rect, in: geometry.size))
                }
                .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                    .position(
                        x: (rect.midX * geometry.size.width),
                        y: (rect.midY * geometry.size.height)
                    )

                ForEach(1..<3, id: \.self) { index in
                    Rectangle()
                        .fill(.white.opacity(0.42))
                        .frame(width: 1, height: rect.height * geometry.size.height)
                        .position(
                            x: (rect.minX + rect.width * CGFloat(index) / 3) * geometry.size.width,
                            y: rect.midY * geometry.size.height
                        )
                    Rectangle()
                        .fill(.white.opacity(0.42))
                        .frame(width: rect.width * geometry.size.width, height: 1)
                        .position(
                            x: rect.midX * geometry.size.width,
                            y: (rect.minY + rect.height * CGFloat(index) / 3) * geometry.size.height
                        )
                }

                ForEach(CropHandle.allCases, id: \.self) { handle in
                    handleView(handle, rect: rect, size: geometry.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(rect: rect, size: geometry.size))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crop editor")
    }

    private func displayRect(for size: CGSize) -> CGRect {
        if let cropRect {
            return clamped(cropRect)
        }

        guard let ratio = aspect.ratio, size.width > 0, size.height > 0 else {
            return CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        }

        let normalizedRatio = ratio * size.height / size.width
        var width = 0.84
        var height = width / normalizedRatio
        if height > 0.84 {
            height = 0.84
            width = height * normalizedRatio
        }
        return CGRect(
            x: (1 - width) / 2,
            y: (1 - height) / 2,
            width: width,
            height: height
        )
    }

    private func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    private func moveGesture(rect: CGRect, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if moveStart == nil {
                    moveStart = rect
                }
                guard let moveStart else { return }
                let delta = CGSize(
                    width: value.translation.width / max(size.width, 1),
                    height: value.translation.height / max(size.height, 1)
                )
                cropRect = clamped(
                    CGRect(
                        x: moveStart.minX + delta.width,
                        y: moveStart.minY + delta.height,
                        width: moveStart.width,
                        height: moveStart.height
                    )
                )
            }
            .onEnded { _ in
                moveStart = nil
            }
    }

    private func handleView(_ handle: CropHandle, rect: CGRect, size: CGSize) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 1))
            .position(
                x: handle.point(in: rect).x * size.width,
                y: handle.point(in: rect).y * size.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if resizeStart == nil {
                            resizeStart = rect
                        }
                        guard let resizeStart else { return }
                        cropRect = resized(
                            from: resizeStart,
                            handle: handle,
                            translation: value.translation,
                            size: size
                        )
                    }
                    .onEnded { _ in
                        resizeStart = nil
                    }
            )
    }

    private func resized(
        from start: CGRect,
        handle: CropHandle,
        translation: CGSize,
        size: CGSize
    ) -> CGRect {
        let dx = translation.width / max(size.width, 1)
        let dy = translation.height / max(size.height, 1)
        let minimum = 0.08

        if let ratio = aspect.ratio {
            let normalizedRatio = ratio * size.height / max(size.width, 1)
            switch handle {
            case .topLeading:
                var width = max(minimum, start.maxX - min(start.maxX - minimum, start.minX + dx))
                var height = width / normalizedRatio
                if start.maxY - height < 0 {
                    height = start.maxY
                    width = height * normalizedRatio
                }
                return clamped(CGRect(x: start.maxX - width, y: start.maxY - height, width: width, height: height))
            case .topTrailing:
                var width = max(minimum, min(1, start.maxX + dx) - start.minX)
                var height = width / normalizedRatio
                if start.maxY - height < 0 {
                    height = start.maxY
                    width = height * normalizedRatio
                }
                return clamped(CGRect(x: start.minX, y: start.maxY - height, width: width, height: height))
            case .bottomLeading:
                var width = max(minimum, start.maxX - min(start.maxX - minimum, start.minX + dx))
                var height = width / normalizedRatio
                if start.minY + height > 1 {
                    height = 1 - start.minY
                    width = height * normalizedRatio
                }
                return clamped(CGRect(x: start.maxX - width, y: start.minY, width: width, height: height))
            case .bottomTrailing:
                var width = max(minimum, min(1, start.maxX + dx) - start.minX)
                var height = width / normalizedRatio
                if start.minY + height > 1 {
                    height = 1 - start.minY
                    width = height * normalizedRatio
                }
                return clamped(CGRect(x: start.minX, y: start.minY, width: width, height: height))
            }
        }

        var result = start
        switch handle {
        case .topLeading:
            result.origin.x = min(start.maxX - minimum, max(0, start.minX + dx))
            result.origin.y = min(start.maxY - minimum, max(0, start.minY + dy))
        case .topTrailing:
            result.size.width = max(minimum, min(1 - start.minX, start.width + dx))
            result.origin.y = min(start.maxY - minimum, max(0, start.minY + dy))
        case .bottomLeading:
            result.origin.x = min(start.maxX - minimum, max(0, start.minX + dx))
            result.size.height = max(minimum, min(1 - start.minY, start.height + dy))
        case .bottomTrailing:
            result.size.width = max(minimum, min(1 - start.minX, start.width + dx))
            result.size.height = max(minimum, min(1 - start.minY, start.height + dy))
        }
        return clamped(result)
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect.standardized
        result.size.width = min(max(result.width, 0.08), 1)
        result.size.height = min(max(result.height, 0.08), 1)
        result.origin.x = min(max(result.minX, 0), 1 - result.width)
        result.origin.y = min(max(result.minY, 0), 1 - result.height)
        return result
    }
}

private enum CropHandle: CaseIterable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

private extension View {
    func comparisonBadge() -> some View {
        self
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(10)
    }

    func comparisonLabel(alignment: Alignment) -> some View {
        self
            .comparisonBadge()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

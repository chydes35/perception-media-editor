import AppKit
import SwiftUI

/// The photo at one image pixel per screen pixel, for checking focus. Drag to pan; click,
/// Z, or Esc to go back to the fitted view.
struct FocusLoupeView: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.displayScale) private var displayScale
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image = store.focusImage {
                    Image(decorative: image, scale: displayScale)
                        .interpolation(.none)
                        .opacity(store.isLoadingFocus ? 0.55 : 1)
                }

                if store.isLoadingFocus {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.large)
                        if store.focusImage == nil {
                            Text("Decoding at full resolution…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomTrailing) {
                Text("100%  ·  drag to pan  ·  click or Z to exit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(10)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStart == nil { dragStart = store.zoomCenter }
                        guard let dragStart else { return }
                        store.panZoom(
                            from: dragStart,
                            translation: CGSize(
                                width: value.translation.width * displayScale,
                                height: value.translation.height * displayScale
                            )
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture { store.exitZoom100() }
            .onAppear { report(geometry.size) }
            .onChange(of: geometry.size) { _, size in report(size) }
        }
        .accessibilityLabel("Photo at 100 percent")
        .accessibilityHint("Drag to pan. Press Z or Escape to return to the fitted view.")
    }

    private func report(_ size: CGSize) {
        store.setFocusViewport(pixels: CGSize(width: size.width * displayScale, height: size.height * displayScale))
    }
}

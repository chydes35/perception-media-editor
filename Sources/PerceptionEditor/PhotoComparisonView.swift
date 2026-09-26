import AppKit
import SwiftUI

struct PhotoComparisonView: View {
    let original: NSImage?
    let edited: NSImage?
    let mode: PreviewMode

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
        }
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

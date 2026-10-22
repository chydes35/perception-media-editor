import CoreGraphics
import Foundation

/// How a clip's stored frames are turned upright (the track's `preferredTransform`), as the inverse
/// map the fit kernel needs: for a point `p` in the upright frame, the stored point is
/// `(a·p.x + c·p.y + tx, b·p.x + d·p.y + ty)`.
///
/// A custom `AVVideoCompositing` receives stored frames, so a rotated phone clip must be turned
/// here; the built-in compositor would have applied the track transform itself.
struct SourceOrientation: Equatable, Sendable {
    var a: Float
    var b: Float
    var c: Float
    var d: Float
    var tx: Float
    var ty: Float
    var orientedWidth: Float
    var orientedHeight: Float

    init(preferredTransform transform: CGAffineTransform, sourceSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: sourceSize).applying(transform)
        // Orientation is a rotation by quarter turns and/or a mirror; anything else gets the identity.
        guard sourceSize.width > 0, sourceSize.height > 0, abs(transform.a * transform.d - transform.b * transform.c) > 1e-6, bounds.width > 0, bounds.height > 0 else {
            self = .identity(width: Float(sourceSize.width), height: Float(sourceSize.height))
            return
        }
        let inverse = transform.inverted()
        a = Float(inverse.a)
        b = Float(inverse.b)
        c = Float(inverse.c)
        d = Float(inverse.d)
        // The upright frame starts at the transformed bounds' corner, so shift by it before inverting.
        tx = Float(inverse.a * bounds.minX + inverse.c * bounds.minY + inverse.tx)
        ty = Float(inverse.b * bounds.minX + inverse.d * bounds.minY + inverse.ty)
        orientedWidth = Float(bounds.width)
        orientedHeight = Float(bounds.height)
    }

    private init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float, orientedWidth: Float, orientedHeight: Float) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
        self.orientedWidth = orientedWidth; self.orientedHeight = orientedHeight
    }

    static func identity(width: Float, height: Float) -> SourceOrientation {
        SourceOrientation(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0, orientedWidth: width, orientedHeight: height)
    }

    var isIdentity: Bool { a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0 }
    var orientedSize: CGSize { CGSize(width: CGFloat(orientedWidth), height: CGFloat(orientedHeight)) }

    func sourcePoint(forOrientedPoint p: CGPoint) -> CGPoint {
        let x = Float(p.x), y = Float(p.y)
        return CGPoint(x: CGFloat(a * x + c * y + tx), y: CGFloat(b * x + d * y + ty))
    }
}

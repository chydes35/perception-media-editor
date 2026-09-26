import Foundation
import Testing
@testable import PerceptionEditor

struct PhotoAdjustmentTests {
    private let croppedPortrait = PhotoAdjustments(
        exposure: -0.2,
        rotationQuarterTurns: 1,
        cropAspect: .portrait,
        cropRect: CropRect(x: 0.2, y: 0.1, width: 0.5, height: 0.8),
        straightenDegrees: 1.5
    )

    @Test func lookOnlyDropsGeometryAndKeepsTone() {
        let look = croppedPortrait.lookOnly
        #expect(look.exposure == -0.2)
        #expect(look.rotationQuarterTurns == 0)
        #expect(look.cropAspect == .original)
        #expect(look.cropRect == nil)
        #expect(look.straightenDegrees == nil)
    }

    @Test func applyingALookKeepsTheTargetsCropAndRotation() {
        let look = PhotoAdjustments(
            exposure: 0.6,
            vibrance: 0.3,
            rotationQuarterTurns: 3,
            cropAspect: .widescreen,
            cropRect: CropRect(x: 0, y: 0, width: 1, height: 0.5)
        )
        let result = look.look(keepingGeometryOf: croppedPortrait)

        #expect(result.exposure == 0.6)
        #expect(result.vibrance == 0.3)
        #expect(result.rotationQuarterTurns == 1)
        #expect(result.cropAspect == .portrait)
        #expect(result.cropRect == croppedPortrait.cropRect)
        #expect(result.straightenDegrees == 1.5)
    }

    @Test func cropEditingViewKeepsRotationButShowsTheWholeFrame() {
        let uncropped = croppedPortrait.withoutCrop
        #expect(uncropped.cropRect == nil)
        #expect(uncropped.cropAspect == .original)
        #expect(uncropped.rotationQuarterTurns == 1)
        #expect(uncropped.straightenDegrees == 1.5)
    }
}

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

struct WhiteBalanceEyedropperTests {
    @Test func displayedPointsMapToTheUnrotatedRawPixelForEveryOrientation() throws {
        let point = NormalizedPoint(x: 0.2, y: 0.3)
        let size = CGSize(width: 6000, height: 4000)
        let expected: [(CGImagePropertyOrientation, CGPoint)] = [
            (.up, CGPoint(x: 1200, y: 2800)),
            (.upMirrored, CGPoint(x: 4800, y: 2800)),
            (.down, CGPoint(x: 4800, y: 1200)),
            (.downMirrored, CGPoint(x: 1200, y: 1200)),
            (.leftMirrored, CGPoint(x: 1800, y: 3200)),
            (.right, CGPoint(x: 1800, y: 800)),
            (.rightMirrored, CGPoint(x: 4200, y: 800)),
            (.left, CGPoint(x: 4200, y: 3200))
        ]
        for (orientation, pixel) in expected {
            let actual = try #require(WhiteBalanceEyedropper.rawLocation(
                for: point, nativeSize: size, orientation: orientation
            ))
            #expect(abs(actual.x - pixel.x) < 0.01)
            #expect(abs(actual.y - pixel.y) < 0.01)
        }
    }

    @Test func invalidOrOutOfFrameSamplesAreRejected() {
        let size = CGSize(width: 6000, height: 4000)
        #expect(WhiteBalanceEyedropper.rawLocation(
            for: NormalizedPoint(x: 1.1, y: 0.5), nativeSize: size, orientation: .up
        ) == nil)
        #expect(WhiteBalanceEyedropper.rawLocation(
            for: NormalizedPoint(x: .nan, y: 0.5), nativeSize: size, orientation: .up
        ) == nil)
        #expect(WhiteBalanceEyedropper.rawLocation(
            for: NormalizedPoint(x: 0.5, y: 0.5), nativeSize: .zero, orientation: .up
        ) == nil)
        let edge = WhiteBalanceEyedropper.rawLocation(
            for: NormalizedPoint(x: 1, y: 0), nativeSize: size, orientation: .up
        )
        #expect(edge == CGPoint(x: 5999, y: 3999))
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func rawDecoderReturnsKelvinAndTintForANeutralPoint() throws {
        let url = try #require(RawSample.url)
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        let reading = try #require(WhiteBalanceEyedropper.sampleRaw(at: point, url: url))
        let filter = try #require(CIRAWFilter(imageURL: url))
        filter.neutralLocation = try #require(WhiteBalanceEyedropper.rawLocation(
            for: point, nativeSize: filter.nativeSize, orientation: filter.orientation
        ))
        #expect(abs(reading.temperature - Double(filter.neutralTemperature)) < 0.01)
        #expect(abs(reading.tint - Double(filter.neutralTint)) < 0.01)
    }
}

@MainActor
struct WhiteBalancePickerStoreTests {
    private func makeStore() -> EditorStore {
        let defaults = UserDefaults(suiteName: "pme-wb-picker-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/P1001.RW2"),
                               pixelWidth: 6000, pixelHeight: 4000)
        store.project.media = [asset]
        store.select(asset)
        store.workspace = .photo
        store.rawInfo = RawInfo(
            asShotTemperature: 5200, asShotTint: 2,
            defaultLuminanceNoiseReduction: 0, defaultColorNoiseReduction: 0,
            defaultSharpness: 0, defaultDetail: 0,
            supportsNoiseReduction: true, supportsSharpness: true, supportsDetail: true,
            supportsLensCorrection: true, lensCorrectionDefault: true
        )
        return store
    }

    @Test func pickerClosesWithEscapeOrAnotherTool() {
        let store = makeStore()
        store.toggleWhiteBalancePicker()
        #expect(store.isPickingWhiteBalance)
        #expect(store.handleKey("\u{1B}"))
        #expect(!store.isPickingWhiteBalance)
        store.toggleWhiteBalancePicker()
        store.chooseMaskTool(.brush)
        #expect(!store.isPickingWhiteBalance)
        #expect(store.maskTool == .brush)
    }

    @Test func sampledValuesBecomeOneUndoableRawAdjustment() {
        let store = makeStore()
        store.applyWhiteBalanceReading(WhiteBalanceReading(temperature: 6100, tint: -12))
        #expect(store.selectedAdjustments.raw.temperature == 6100)
        #expect(store.selectedAdjustments.raw.tint == -12)
        #expect(store.selectedHistory.map(\.name) == ["Start", "White Balance Eyedropper"])
        store.undoPhotoEdit()
        #expect(store.selectedAdjustments.raw.temperature == nil)
        #expect(store.selectedAdjustments.raw.tint == nil)
    }
}

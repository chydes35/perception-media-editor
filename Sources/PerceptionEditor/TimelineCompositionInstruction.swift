@preconcurrency import AVFoundation
import Foundation

/// A LUT with the content hash that identifies (and caches) its table.
struct ResolvedLUT: Sendable, Equatable {
    var hash: String
    var lut: CubeLUT
}

/// What the compositor does with one clip's frames. Immutable, so any thread may read it.
struct ClipRenderRecipe: Sendable {
    var adjustments: PhotoAdjustments
    var orientation: SourceOrientation
    /// How the source's Y'CbCr was matrixed. The recipe's own pixel format says range and depth.
    var matrix: YCbCrMatrix
    /// Source color: a LUT applied to the decoded code values (such as V-Log to V-709) before
    /// anything treats them as Rec. 709.
    var inputLUT: ResolvedLUT? = nil
    /// Source color through OpenColorIO instead: the grade runs in scene-linear Rec. 709 between
    /// the input transform and the ACES output transform. Takes the place of `inputLUT`.
    var ocioInput: OCIOInputTransform? = nil
}

/// One stretch of the timeline: either a clip's recipe, or (with no recipe) black for a gap.
/// Instructions cover the composition end to end with no overlap, which AVFoundation requires.
final class TimelineCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let sourceTrackID: CMPersistentTrackID
    let recipe: ClipRenderRecipe?
    /// Tests give a composition a key to read its compositor's counters.
    let statisticsKey: UUID?

    init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, recipe: ClipRenderRecipe?, statisticsKey: UUID? = nil) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.recipe = recipe
        self.statisticsKey = statisticsKey
        requiredSourceTrackIDs = recipe == nil ? [] : [NSNumber(value: sourceTrackID)]
        super.init()
    }
}

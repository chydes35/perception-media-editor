import Foundation

struct PhotoUndoStep {
    struct Change {
        let before: PhotoAdjustments?
        let after: PhotoAdjustments?
    }

    let changes: [UUID: Change]
    let retainedCost: Int

    init(before: [UUID: PhotoAdjustments], after: [UUID: PhotoAdjustments]) {
        var changes: [UUID: Change] = [:]
        for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
            changes[id] = Change(before: before[id], after: after[id])
        }
        self.changes = changes
        retainedCost = changes.values.reduce(0) {
            $0 + 128 + ($1.before?.estimatedRetainedCost ?? 0) + ($1.after?.estimatedRetainedCost ?? 0)
        }
    }
}

/// Undo and redo share one budget. Moving a step between the stacks retains no new snapshot.
struct PhotoUndoHistory {
    static let maximumSteps = 100
    static let maximumRetainedCost = 32 * 1024 * 1024

    private(set) var undo: [PhotoUndoStep] = []
    private(set) var redo: [PhotoUndoStep] = []
    private(set) var retainedCost = 0
    let stepLimit: Int
    let costLimit: Int

    init(stepLimit: Int = maximumSteps, costLimit: Int = maximumRetainedCost) {
        self.stepLimit = max(0, stepLimit)
        self.costLimit = max(0, costLimit)
    }

    @discardableResult
    mutating func record(before: [UUID: PhotoAdjustments], after: [UUID: PhotoAdjustments]) -> Bool {
        let step = PhotoUndoStep(before: before, after: after)
        guard !step.changes.isEmpty else { return true }
        retainedCost -= redo.reduce(0) { $0 + $1.retainedCost }
        redo.removeAll()
        guard stepLimit > 0, step.retainedCost <= costLimit else {
            // An unrecorded change breaks the chain. Older steps must not overwrite it later.
            clear()
            return false
        }
        undo.append(step)
        retainedCost += step.retainedCost
        while undo.count > stepLimit || retainedCost > costLimit {
            retainedCost -= undo.removeFirst().retainedCost
        }
        return true
    }

    mutating func undoStep() -> PhotoUndoStep? {
        guard let step = undo.popLast() else { return nil }
        redo.append(step)
        return step
    }

    mutating func redoStep() -> PhotoUndoStep? {
        guard let step = redo.popLast() else { return nil }
        undo.append(step)
        return step
    }

    mutating func clear() {
        undo.removeAll()
        redo.removeAll()
        retainedCost = 0
    }
}

extension PhotoAdjustments {
    /// Conservative accounting for variable-size brush/curve data, with capacity/overhead
    /// allowance. This is a retention budget, not a measurement of process resident memory.
    var estimatedRetainedCost: Int {
        let curvePoints = [curves.rgb, curves.red, curves.green, curves.blue]
            .compactMap { $0 }.reduce(0) { $0 + $1.points.count }
        return 1024 + curvePoints * 32 + masks.reduce(0) { cost, mask in
            let pointsCost: Int
            if case .brush(let strokes) = mask.shape {
                pointsCost = strokes.reduce(0) { $0 + 128 + $1.points.count * 32 }
            } else {
                pointsCost = 0
            }
            return cost + 512 + (mask.name?.utf8.count ?? 0) * 2 + pointsCost
        }
    }
}

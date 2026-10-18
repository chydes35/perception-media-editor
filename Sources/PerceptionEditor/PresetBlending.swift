import Foundation

extension PhotoAdjustments {
    /// This photo with `groups` of `source` applied at `amount` (0 = unchanged, 1 = fully applied).
    /// Sliders and curves move that fraction of the way; switches (lens correction) and
    /// masks only change once the amount reaches 1, because they have no halfway state.
    func applying(_ source: PhotoAdjustments, groups: Set<AdjustmentGroup>, amount: Double) -> PhotoAdjustments {
        let t = min(1, max(0, amount))
        let full = applying(source, groups: groups)
        guard t < 1 else { return full }
        guard t > 0 else { return self }

        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        func mix(_ a: Double?, _ b: Double?, neutral: Double = 0) -> Double? {
            guard a != nil || b != nil else { return nil }
            return mix(a ?? neutral, b ?? neutral)
        }

        var result = self
        result.exposure = mix(exposure, full.exposure)
        result.contrast = mix(contrast, full.contrast)
        result.highlights = mix(highlights, full.highlights)
        result.shadows = mix(shadows, full.shadows)
        result.temperature = mix(temperature, full.temperature)
        result.tint = mix(tint, full.tint)
        result.vibrance = mix(vibrance, full.vibrance)
        result.saturation = mix(saturation, full.saturation)
        result.sharpness = mix(sharpness, full.sharpness)
        result.vignette = mix(vignette, full.vignette)

        // White balance has no neutral Kelvin, so it only moves when both sides have one.
        if let a = raw.temperature, let b = full.raw.temperature { result.raw.temperature = mix(a, b) }
        if let a = raw.tint, let b = full.raw.tint { result.raw.tint = mix(a, b) }
        result.raw.luminanceNoiseReduction = mix(raw.luminanceNoiseReduction, full.raw.luminanceNoiseReduction)
        result.raw.colorNoiseReduction = mix(raw.colorNoiseReduction, full.raw.colorNoiseReduction)
        result.raw.sharpness = mix(raw.sharpness, full.raw.sharpness)
        result.raw.detail = mix(raw.detail, full.raw.detail)

        for channel in ToneCurves.Channel.allCases {
            result.curves[channel] = Self.blend(curves[channel], full.curves[channel], amount: t)
        }
        result.hsl = Self.blend(hsl, full.hsl, amount: t)
        result.grading = Self.blend(grading, full.grading, amount: t)
        result.grain = Self.blend(grain, full.grain, amount: t)
        return result
    }

    /// Curves are compared at the target curve's own points, so the blend keeps its point count.
    private static func blend(_ a: ToneCurve?, _ b: ToneCurve?, amount t: Double) -> ToneCurve? {
        guard a != nil || b != nil else { return nil }
        let from = a ?? .linear
        let to = b ?? .linear
        let anchors = (b == nil ? from : to).points
        let points = anchors.map { CurvePoint(x: $0.x, y: from.evaluate($0.x) + (to.evaluate($0.x) - from.evaluate($0.x)) * t) }
        return ToneCurve(points: points)
    }

    private static func blend(_ a: ColorGradeAdjustments?, _ b: ColorGradeAdjustments?, amount t: Double) -> ColorGradeAdjustments? {
        guard a != nil || b != nil else { return nil }
        let from = a ?? ColorGradeAdjustments()
        let to = b ?? ColorGradeAdjustments()
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var result = ColorGradeAdjustments()
        result.blending = mix(from.blending, to.blending)
        result.balance = mix(from.balance, to.balance)
        for zone in ColorGradeAdjustments.Zone.allCases {
            let x = from[zone], y = to[zone]
            // Hue is a position on a circle, so a zone with no tint takes the other side's hue.
            let hue = x.saturation == 0 ? y.hue : (y.saturation == 0 ? x.hue : mix(x.hue, y.hue))
            result[zone] = GradeZone(hue: hue, saturation: mix(x.saturation, y.saturation), luminance: mix(x.luminance, y.luminance))
        }
        return result.isNeutral ? nil : result
    }

    private static func blend(_ a: GrainAdjustments?, _ b: GrainAdjustments?, amount t: Double) -> GrainAdjustments? {
        guard a != nil || b != nil else { return nil }
        let from = a ?? GrainAdjustments(amount: 0, size: b?.size ?? 0.25, roughness: b?.roughness ?? 0.5)
        let to = b ?? GrainAdjustments(amount: 0, size: a?.size ?? 0.25, roughness: a?.roughness ?? 0.5)
        let mixed = GrainAdjustments(
            amount: from.amount + (to.amount - from.amount) * t,
            size: from.size + (to.size - from.size) * t,
            roughness: from.roughness + (to.roughness - from.roughness) * t
        )
        return mixed.isNeutral ? nil : mixed
    }

    private static func blend(_ a: HSLAdjustments?, _ b: HSLAdjustments?, amount t: Double) -> HSLAdjustments? {
        guard a != nil || b != nil else { return nil }
        let from = a ?? HSLAdjustments()
        let to = b ?? HSLAdjustments()
        var result = HSLAdjustments()
        for band in HSLBand.allCases {
            let x = from[band], y = to[band]
            let mixed = HSLBandAdjustment(
                hue: x.hue + (y.hue - x.hue) * t,
                saturation: x.saturation + (y.saturation - x.saturation) * t,
                luminance: x.luminance + (y.luminance - x.luminance) * t
            )
            switch band {
            case .red: result.red = mixed
            case .orange: result.orange = mixed
            case .yellow: result.yellow = mixed
            case .green: result.green = mixed
            case .aqua: result.aqua = mixed
            case .blue: result.blue = mixed
            case .purple: result.purple = mixed
            case .magenta: result.magenta = mixed
            }
        }
        return result.isNeutral ? nil : result
    }
}

extension PhotoPreset {
    /// `target` with this preset applied at `amount` (1 = fully).
    func apply(to target: PhotoAdjustments, amount: Double) -> PhotoAdjustments {
        target.applying(adjustments, groups: effectiveGroups, amount: amount)
    }
}

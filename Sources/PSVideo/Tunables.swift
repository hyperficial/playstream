import Foundation

/// Every runtime-adjustable constant that shapes pacing, frame generation, rendering and scaling.
/// Components take a snapshot (`Tunables.values`) once per frame, so a change applies from the next
/// frame and never half-way through one. Names, ranges, defaults and meanings are in `Tunables.specs`.
struct TunableValues {
	// Pacing (FramePacer).
	var pacerMinDelayMs = 1000.0 / 60
	var pacerMaxDelayMs = 50.0
	var pacerPercentile = 0.99
	var pacerMarginMs = 2.0
	var pacerDecayMsPerSecond = 10.0
	var pacerCatchUp = 0.10
	var pacerFastCatchUp = 0.50
	var pacerSkipFrames = 3.0
	var pacerWindowSeconds = 2.0
	var pacerStatsWindowSeconds = 5.0
	var pacerWarmupSeconds = 0.5
	var pacerOutlierFraction = 0.75
	var pacerOutlierMaxDelayFraction = 0.75
	var pacerRebaseCount = 2.0
	var pacerRebaseSpreadFraction = 0.25
	var pacerBurstSkipFraction = 0.25
	var pacerRateTolerance = 0.12
	var pacerRateMismatchFrames = 10.0
	// Rendering (MetalVideoRenderer / layer path).
	var renderAheadRefreshes = 2.0
	var renderAheadExtraMs = 4.0
	var renderQueueCapacity = 16.0
	var renderPresentLeadRefreshes = 0.0
	var layerLeadCapMs = 1000.0 / 60
	// Frame generation, both methods (FrameGenerator).
	var fgCommitMarginMs = 12.0
	var fgMaxAddedLatencyMs = 45.0
	var fgProcEstimateMs = 12.0
	var fgProcPercentile = 0.95
	var fgRepeatChangedLevel = 6.0
	var fgRepeatFraction = 0.004
	var fgCutHistDistance = 0.5
	var fgCutResidual = 0.6
	var fgCutHistHard = 1.2
	var fgCutHistNoMotion = 1.0
	var fgEnterIsolatedRepeats = 4.0
	var fgExitAllNew = 12.0
	var fgShiftEarlierSeconds = 6.0
	var fgLateNoShiftFraction = 0.6
	var fgGuardCodes = 3.5
	// Extrapolation (MotionExtrapolator + decision).
	var exMaxResidual = 0.75
	var exFieldChangeAbsPx = 6.0
	var exFieldChangeRel = 0.5
	var exFactorScale = 1.0
	var exSearchRange16 = 8.0
	var exRefineRange8 = 2.0
	var exRefineRange4 = 1.0
	var exBlockConfidence = 0.6
	var exChangedBlockSad = 0.5
	var exOverlayRatio = 0.6
	var exOverlayMaxCodes = 6.0
	// Scaling (FrameScaler).
	var scalerSharpness = 0.5
	var scalerMetalFXHDRLinear = 1.0
	// Presentation (MetalVideoRenderer).
	var presentMode = 0.0
	var presentDrawableCount = 3.0
	var presentDisplaySync = 1.0
	var presentCommitAheadMs = 6.0
	var presentKeepAliveFraction = 0.9
	var presentKeepAliveAllModes = 0.0
	var presentKeepAliveStreamIntervals = 1.5
	var presentFullLayer = 0.0
	var presentHUD = 0.0
	var presentSampleDisplayUpdates = 0.0
	// In-frame overlay.
	var overlayHDRWhiteNits = 100.0
	var overlayOpacity = 1.0
}

final class Tunables: @unchecked Sendable {
	struct Spec {
		let name: String
		let key: WritableKeyPath<TunableValues, Double>
		let range: ClosedRange<Double>
		let doc: String
	}

	static let specs: [Spec] = [
		Spec(name: "pacer.minDelayMs", key: \.pacerMinDelayMs, range: 0...200, doc: "lowest playout delay the jitter buffer settles at (ms)"),
		Spec(name: "pacer.maxDelayMs", key: \.pacerMaxDelayMs, range: 0...500, doc: "highest playout delay target (ms); late frames can exceed it briefly"),
		Spec(name: "pacer.percentile", key: \.pacerPercentile, range: 0.5...1, doc: "lateness percentile over the window that sets the delay target"),
		Spec(name: "pacer.marginMs", key: \.pacerMarginMs, range: 0...30, doc: "added to the lateness percentile (ms)"),
		Spec(name: "pacer.decayMsPerSecond", key: \.pacerDecayMsPerSecond, range: 0...500, doc: "how fast the delay target falls when lateness drops (ms per second)"),
		Spec(name: "pacer.catchUp", key: \.pacerCatchUp, range: 0...0.9, doc: "fraction of a frame interval the applied delay may shrink per frame"),
		Spec(name: "pacer.fastCatchUp", key: \.pacerFastCatchUp, range: 0...1, doc: "same, while the applied delay is above the maximum"),
		Spec(name: "pacer.skipFrames", key: \.pacerSkipFrames, range: 0.5...30, doc: "skip frames when the applied delay exceeds the target by this many intervals"),
		Spec(name: "pacer.windowSeconds", key: \.pacerWindowSeconds, range: 0.25...20, doc: "window for the arrival-grid base and the lateness percentile (s)"),
		Spec(name: "pacer.statsWindowSeconds", key: \.pacerStatsWindowSeconds, range: 1...20, doc: "window for the arrival jitter / gap statistics (s)"),
		Spec(name: "pacer.warmupSeconds", key: \.pacerWarmupSeconds, range: 0...10, doc: "lateness ignored for the delay target after stream start (s)"),
		Spec(name: "pacer.outlierFraction", key: \.pacerOutlierFraction, range: 0.2...10, doc: "lateness >= this x interval is an outlier (missed console frame / stall), not jitter"),
		Spec(name: "pacer.outlierMaxDelayFraction", key: \.pacerOutlierMaxDelayFraction, range: 0.2...10, doc: "above 45 fps an outlier must also exceed this x max delay"),
		Spec(name: "pacer.rebaseCount", key: \.pacerRebaseCount, range: 1...20, doc: "consecutive equally-late outliers that re-base the grid (console timeline slipped)"),
		Spec(name: "pacer.rebaseSpreadFraction", key: \.pacerRebaseSpreadFraction, range: 0...2, doc: "max spread of their lateness, x interval"),
		Spec(name: "pacer.burstSkipFraction", key: \.pacerBurstSkipFraction, range: 0...1, doc: "skip a frame whose target is within this x interval of the last shown one"),
		Spec(name: "pacer.rateTolerance", key: \.pacerRateTolerance, range: 0.01...0.5, doc: "relative error to snap the measured frame rate to nominal / 2 / 3 / 4"),
		Spec(name: "pacer.rateMismatchFrames", key: \.pacerRateMismatchFrames, range: 1...200, doc: "frames of consistent rate mismatch before the grid follows"),
		Spec(name: "render.aheadRefreshes", key: \.renderAheadRefreshes, range: 0...8, doc: "paced frames are rendered this many refreshes before their requested time"),
		Spec(name: "render.aheadExtraMs", key: \.renderAheadExtraMs, range: 0...50, doc: "plus this many ms"),
		Spec(name: "render.queueCapacity", key: \.renderQueueCapacity, range: 2...64, doc: "paced pictures waiting to be rendered before the oldest is dropped"),
		Spec(name: "render.presentLeadRefreshes", key: \.renderPresentLeadRefreshes, range: -1...3, doc: "requested present time = target + this x refresh (no slot clock)"),
		Spec(name: "layer.leadCapMs", key: \.layerLeadCapMs, range: 0...100, doc: "layer path: cap of the learned presentation lead (ms)"),
		Spec(name: "fg.commitMarginMs", key: \.fgCommitMarginMs, range: 0...60, doc: "a generated picture must be handed over this long before its vsync (ms)"),
		Spec(name: "fg.maxAddedLatencyMs", key: \.fgMaxAddedLatencyMs, range: 0...300, doc: "interpolation: most extra delay over the non-generating path (ms)"),
		Spec(name: "fg.procEstimateMs", key: \.fgProcEstimateMs, range: 1...100, doc: "interpolation time assumed before measurements exist (ms)"),
		Spec(name: "fg.procPercentile", key: \.fgProcPercentile, range: 0.5...1, doc: "percentile of measured interpolation time used in the budget"),
		Spec(name: "fg.repeatChangedLevel", key: \.fgRepeatChangedLevel, range: 1...128, doc: "luma difference (8-bit codes) that counts a pixel as changed"),
		Spec(name: "fg.repeatFraction", key: \.fgRepeatFraction, range: 0...0.5, doc: "fewer changed pixels than this fraction: a repeated picture"),
		Spec(name: "fg.cutHistDistance", key: \.fgCutHistDistance, range: 0...2, doc: "histogram L1 distance that makes a cut candidate"),
		Spec(name: "fg.cutResidual", key: \.fgCutResidual, range: 0...1, doc: "a candidate is a cut if motion leaves more than this residual ratio"),
		Spec(name: "fg.cutHistHard", key: \.fgCutHistHard, range: 0...2, doc: "histogram distance that is a cut regardless of motion"),
		Spec(name: "fg.cutHistNoMotion", key: \.fgCutHistNoMotion, range: 0...2, doc: "histogram distance that is a cut when no motion estimate exists"),
		Spec(name: "fg.enterIsolatedRepeats", key: \.fgEnterIsolatedRepeats, range: 1...30, doc: "isolated repeats in the last 24 pictures to enter fill mode (60 fps stream)"),
		Spec(name: "fg.exitAllNew", key: \.fgExitAllNew, range: 2...120, doc: "consecutive new pictures to leave fill mode (true 60 fps content)"),
		Spec(name: "fg.shiftEarlierSeconds", key: \.fgShiftEarlierSeconds, range: 0.5...120, doc: "interpolation slot clock moves a slot earlier after this long with spare time (s)"),
		Spec(name: "fg.lateNoShiftFraction", key: \.fgLateNoShiftFraction, range: 0...5, doc: "a real picture later than this x content interval does not move the slot clock"),
		Spec(name: "fg.guardCodes", key: \.fgGuardCodes, range: 0...64, doc: "interpolation static-overlay guard: max 3x3 change (8-bit codes) to keep the real pixel"),
		Spec(name: "ex.maxResidual", key: \.exMaxResidual, range: 0...1, doc: "extrapolation rejected when motion leaves more than this residual ratio (low confidence)"),
		Spec(name: "ex.fieldChangeAbsPx", key: \.exFieldChangeAbsPx, range: 0...500, doc: "rejected when the motion field changed more than max(this, rel x mean motion) px"),
		Spec(name: "ex.fieldChangeRel", key: \.exFieldChangeRel, range: 0...10, doc: "relative part of that limit"),
		Spec(name: "ex.factorScale", key: \.exFactorScale, range: 0...2, doc: "scales how far ahead the picture is predicted (1 = exactly half a content interval)"),
		Spec(name: "ex.searchRange16", key: \.exSearchRange16, range: 1...16, doc: "block search range at 1/16 resolution (x16 = full-resolution px)"),
		Spec(name: "ex.refineRange8", key: \.exRefineRange8, range: 0...4, doc: "refinement range at 1/8 resolution (px)"),
		Spec(name: "ex.refineRange4", key: \.exRefineRange4, range: 0...4, doc: "refinement range at 1/4 resolution (px)"),
		Spec(name: "ex.blockConfidence", key: \.exBlockConfidence, range: 0...1, doc: "a block's vector is trusted when its match error < this x no-motion error"),
		Spec(name: "ex.changedBlockSad", key: \.exChangedBlockSad, range: 0...64, doc: "block SAD (sum over 8x8, 0..1 luma) below which a block 'did not change'"),
		Spec(name: "ex.overlayRatio", key: \.exOverlayRatio, range: 0...1, doc: "overlay guard: static error < this x moved error keeps the real pixel"),
		Spec(name: "ex.overlayMaxCodes", key: \.exOverlayMaxCodes, range: 0...128, doc: "overlay guard: and static error per tap below this many 8-bit codes"),
		Spec(name: "scaler.sharpness", key: \.scalerSharpness, range: 0...1, doc: "FSR 1 RCAS sharpening (0 = off, 1 = AMD maximum)"),
		Spec(name: "scaler.metalFXHDRLinear", key: \.scalerMetalFXHDRLinear, range: 0...1, doc: "MetalFX on HDR: 1 = linear-light HDR mode, 0 = PQ values in perceptual mode"),
		Spec(name: "present.mode", key: \.presentMode, range: 0...2, doc: "Metal presentation: 0 = paced grid (as before), 1 = lowest latency (each picture presented as soon as decoded, newest wins), 2 = smooth (presentAtTime at the pacer's continuous target)"),
		Spec(name: "present.drawableCount", key: \.presentDrawableCount, range: 2...3, doc: "CAMetalLayer.maximumDrawableCount (2 = less buffering, may wait for a drawable)"),
		Spec(name: "present.displaySync", key: \.presentDisplaySync, range: 0...1, doc: "CAMetalLayer.displaySyncEnabled (0 = may tear on non-VRR paths)"),
		Spec(name: "present.commitAheadMs", key: \.presentCommitAheadMs, range: 0...50, doc: "modes 1/2: a timed picture is rendered and committed this long before its requested time (ms)"),
		Spec(name: "present.keepAliveFraction", key: \.presentKeepAliveFraction, range: 0...1, doc: "re-present the last picture when nothing was presented for this x the panel's maximum refresh interval (0 = off; modes 1/2 unless keepAliveAllModes)"),
		Spec(name: "present.keepAliveStreamIntervals", key: \.presentKeepAliveStreamIntervals, range: 0...10, doc: "and only when the stream is this many of its own intervals overdue (keeps re-presents out of normal jitter; 0 = panel limit only)"),
		Spec(name: "present.keepAliveAllModes", key: \.presentKeepAliveAllModes, range: 0...1, doc: "1 = keep-alive also in mode 0"),
		Spec(name: "present.fullLayer", key: \.presentFullLayer, range: 0...1, doc: "1 = direct-to-display layout: Metal layer covers the whole view at native pixels, letterbox drawn into the drawable, no painting PSVideo layers"),
		Spec(name: "present.hud", key: \.presentHUD, range: 0...1, doc: "1 = Apple's Metal performance HUD on the video layer (developerHUDProperties)"),
		Spec(name: "present.sampleDisplayUpdates", key: \.presentSampleDisplayUpdates, range: 0...1, doc: "1 = poll NSScreen.lastDisplayUpdateTimestamp (~2 kHz, background thread) for display-update cadence stats"),
		Spec(name: "overlay.hdrWhiteNits", key: \.overlayHDRWhiteNits, range: 20...1000, doc: "in-frame overlay: luminance of overlay white on HDR output (nits; 100 = SDR reference white)"),
		Spec(name: "overlay.opacity", key: \.overlayOpacity, range: 0...1, doc: "in-frame overlay: global opacity multiplier"),
	]

	private let lock = UnfairLock()
	private var v = TunableValues()
	private(set) var version = 0

	var values: TunableValues { lock.withLock { v } }

	func get(_ name: String) -> Double? {
		guard let s = Self.specs.first(where: { $0.name == name }) else { return nil }
		return lock.withLock { v[keyPath: s.key] }
	}

	@discardableResult
	func set(_ name: String, _ value: Double) -> Bool {
		guard value.isFinite, let s = Self.specs.first(where: { $0.name == name }), s.range.contains(value) else { return false }
		lock.withLock {
			v[keyPath: s.key] = value
			version += 1
		}
		return true
	}

	func all() -> [String: Double] {
		let snap = values
		var d: [String: Double] = [:]
		for s in Self.specs { d[s.name] = snap[keyPath: s.key] }
		return d
	}
}

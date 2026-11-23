import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import VideoToolbox

/// Frame generation for the Metal path: synthesises in-between pictures so content below the
/// display cadence plays evenly.
public enum VideoFrameGeneration: String, Sendable, CaseIterable, Codable {
	case off
	/// Content below 60 fps -> 60 fps. A 30 fps game arrives either as a 60 fps stream in which every
	/// second picture is a repeat (each repeat is replaced by a generated in-between picture) or as a
	/// 30 fps stream (a picture is generated between each pair). 60 fps content passes through with no
	/// added latency.
	case to60
	/// As `.to60`, and 60 fps content is doubled to 120 fps for a 120 Hz display.
	case to120
}

/// How in-between pictures are made.
public enum VideoFrameGenerationMethod: String, Sendable, CaseIterable, Codable {
	/// Predict the next in-between picture from the motion between the last two real pictures and show
	/// it half a content interval after the current one. Real pictures are shown exactly when the
	/// non-generating path would show them: no added input delay. Artefacts where motion changes
	/// (stops, reverses) and at disocclusions; such slots fall back to the real picture.
	case extrapolate
	/// Interpolate between two real pictures (VideoToolbox ML interpolator). Smoothest and most correct,
	/// but every real picture waits for the next one: about half a content interval + interpolation time
	/// of added delay.
	case interpolate
}

/// One picture handed to the display queue.
struct GeneratedEmit {
	enum Kind { case real, generated, fallbackRepeat }
	var buffer: CVPixelBuffer
	var arrival: UInt64
	var target: Double
	var interval: Double
	var kind: Kind
	/// Decode-order index of the stream picture this shows (generated: the slot it fills).
	var sourceIndex: Int
	/// Exact requested presentation time (slot clock); nil = renderer derives it from `target`.
	var presentAt: Double? = nil
}

/// Runs on its own serial queue. Feed decoded frames in decode order with `submit`; pictures come out
/// through `emit` in presentation order with their target times (host seconds, before the renderer's
/// presentation lead).
final class FrameGenerator {
	struct Input {
		var buffer: CVPixelBuffer
		var arrival: UInt64
		var target: Double
		var interval: Double
		var skip: Bool
		/// Frames lost / repaired / decode error just before this one: never interpolate across it.
		var discontinuity: Bool
		/// From the pacer: best-case arrival grid time, raw jitter allowance, applied pacer delay.
		var grid: Double = 0
		var jitter: Double = 0
		var pacerDelay: Double = 0
	}

	/// Display vsync phase and period (from the view's display link); nil when unknown (headless).
	var vsync: (() -> (phase: Double, period: Double)?)?
	/// Most extra delay over the non-generating paced path the generator may use. Below what the
	/// interpolation needs, more in-between pictures miss their slot and fall back.
	var maxAddedLatency = 0.045
	/// Extrapolate (no added delay) or interpolate.
	var method: VideoFrameGenerationMethod = .extrapolate
	private lazy var extrapolator: MotionExtrapolator? = MotionExtrapolator(device: device)
	private var lastMotion: MotionExtrapolator.Motion?
	private var extrapolated = 0, extrapolationRejected = 0
	private var motionMs = 0.0, warpMs = 0.0

	var emit: ((GeneratedEmit) -> Void)?
	private let queue = DispatchQueue(label: "PSVideo.framegen", qos: .userInteractive)
	private let setupQueue = DispatchQueue(label: "PSVideo.framegen-setup", qos: .userInitiated)
	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let stats: StatsCollector
	private var textureCache: CVMetalTextureCache
	private let analyzePSO: MTLComputePipelineState
	private let dither8Y: MTLRenderPipelineState
	private let dither8C: MTLRenderPipelineState
	private let protectY: MTLRenderPipelineState
	private let protectC: MTLRenderPipelineState
	/// Static-overlay guard on/off (diagnostics compare both).
	var staticGuard = ProcessInfo.processInfo.environment["PSVIDEO_FG_NO_GUARD"] == nil

	// Settings (queue).
	private var mode: VideoFrameGeneration = .off

	// VT interpolator (queue). Created on setupQueue.
	private var processor: VTFrameProcessor?
	private var processorSize = (0, 0)
	private var settingUp = false
	/// Diagnostics asked for the interpolator while frame generation is off: keep the session.
	private var diagnosticHold = false
	private var pool8: CVPixelBufferPool?
	private var poolOut: CVPixelBufferPool?

	// Picture analysis.
	private struct Picture {
		var buffer: CVPixelBuffer
		var buffer8: CVPixelBuffer?
		var hist: [Float]
		var input: Input
		var index: Int
	}
	private var lastPicture: Picture?
	private var lastNew: Picture?
	private var index = 0

	// Cadence.
	private var history: [Bool] = [] // true = new picture
	enum Cadence: String { case native, fillRepeats, doubling }
	private var cadence: Cadence = .native
	private(set) var contentFPS: Double = 0

	// Slot clock (generating only): output pictures sit on consecutive vsync-aligned slots.
	private struct Clock {
		var anchorGrid: Double     // grid time of output slot 0
		var anchorDisplay: Double  // vsync time at which output slot 0 is shown
		var periodOut: Double      // output picture period in grid time (stream interval, or half of it when doubling)
		var slotDur: Double        // whole refreshes per output picture
		var refresh: Double
		var windowStart: Double
		var minSlack: Double       // smallest commit slack seen in the window (s)
		var missed: Bool           // a slot was missed in the window
	}
	private var clock: Clock?
	private var slotShifts = 0
	private var lateReal = 0
	private var addedLatency = 0.0
	private var procTimes = Ring(capacity: 64)
	private var convertMs = 0.0, guardMs = 0.0
	/// Commit margin before a slot's vsync: render (+ upscale) GPU time and the compositor's own lead.
	let commitMargin = 0.012
	private var procScratch = [Double](repeating: 0, count: 64)

	/// Output queue in presentation order. Real pictures are ready at once; an in-between slot waits for
	/// the next real picture, then for its interpolation, and falls back at its deadline. Pictures leave
	/// strictly from the head, so presentation order never inverts, whatever the arrival pattern.
	private final class Slot {
		let isGen: Bool
		var emit: GeneratedEmit?
		var done: Bool
		var prev: Picture?
		var next: Picture?
		var fallback: Input?
		var target: Double
		var interval: Double
		var index: Int
		var started = false
		var presentAt: Double?
		init(isGen: Bool, emit: GeneratedEmit?, target: Double, interval: Double, index: Int) {
			self.isGen = isGen
			self.emit = emit
			self.done = !isGen
			self.target = target
			self.interval = interval
			self.index = index
		}
	}
	private var slots: [Slot] = []
	private var interpolating = false

	// Thresholds (8-bit luma code values; fractions of sampled pixels).
	let changedLevel: Float = 6       // |diff| above this counts as a changed pixel
	let repeatFraction: Float = 0.004 // fewer changed pixels than this: same picture (encoder refinement)
	let cutHistDistance: Float = 0.5  // L1 distance of normalised 32-bin histograms: scene cut

	// Counters.
	private var generated = 0, fallbacks = 0, cutsSkipped = 0
	private var genWindowStart = 0.0, genWindowCount = 0

	init?(device: MTLDevice, stats: StatsCollector) {
		self.device = device
		self.stats = stats
		guard let q = device.makeCommandQueue() else { return nil }
		commandQueue = q
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
		textureCache = cache
		guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
		      let lib = try? device.makeLibrary(source: Self.shaders, options: nil),
		      let f = lib.makeFunction(name: "psv_analyze"),
		      let a = try? device.makeComputePipelineState(function: f)
		else { return nil }
		analyzePSO = a
		func rp(_ frag: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
			let d = MTLRenderPipelineDescriptor()
			d.vertexFunction = lib.makeFunction(name: "psv_fg_vertex")
			d.fragmentFunction = lib.makeFunction(name: frag)
			d.colorAttachments[0].pixelFormat = fmt
			return try? device.makeRenderPipelineState(descriptor: d)
		}
		guard let y = rp("psv_dither_y", .r8Unorm), let c = rp("psv_dither_c", .rg8Unorm),
		      let py = rp("psv_protect_y", .r8Unorm), let pc = rp("psv_protect_c", .rg8Unorm) else { return nil }
		dither8Y = y
		dither8C = c
		protectY = py
		protectC = pc
	}

	// MARK: Control

	func setMode(_ m: VideoFrameGeneration) {
		queue.async {
			self.mode = m
			if m == .off {
				self.flushSlots()
				self.cadence = .native
				self.clock = nil
				self.processor?.endSession()
				self.processor = nil
			}
			self.publish()
		}
	}

	func setMethod(_ m: VideoFrameGenerationMethod) {
		queue.async {
			guard self.method != m else { return }
			self.flushSlots()
			self.method = m
			self.clock = nil
			self.extrapolatedFor = nil
			self.extrapolator?.resetHistory()
			self.publish()
		}
	}

	func reset() {
		queue.async {
			self.flushSlots()
			self.lastPicture = nil
			self.lastNew = nil
			self.history.removeAll()
			self.cadence = .native
			self.clock = nil
			self.contentFPS = 0
			self.stoppedState = true
			self.publish()
		}
	}

	private let debug = ProcessInfo.processInfo.environment["PSVIDEO_DEBUG_FG"] != nil
	private let depthLock = UnfairLock()
	private var depth = 0

	func submit(_ input: Input) {
		let d = depthLock.withLock { () -> Int in depth += 1; return depth }
		if debug && d > 2 { NSLog("[PSVideo fg] queue depth %d", d) }
		queue.async {
			let t0 = CACurrentMediaTime()
			self.process(input)
			self.depthLock.withLock { self.depth -= 1 }
			if self.debug { NSLog("[PSVideo fg] process %.2f ms (cadence %@)", (CACurrentMediaTime() - t0) * 1000, self.cadence.rawValue) }
		}
	}

	// MARK: Pipeline

	private func process(_ input: Input) {
		index += 1
		let idx = index
		let w = CVPixelBufferGetWidth(input.buffer), h = CVPixelBufferGetHeight(input.buffer)
		if mode != .off { ensureProcessor(w, h) }

		// 1. Analysis against the previous picture.
		let (changed, hist) = analyze(input.buffer, previous: lastPicture?.buffer)
		let isRepeat = lastPicture != nil && changed < repeatFraction && !input.discontinuity
		var pic = Picture(buffer: input.buffer, buffer8: nil, hist: hist, input: input, index: idx)

		// 2. Cadence.
		history.append(!isRepeat)
		if history.count > 30 { history.removeFirst(history.count - 30) }
		updateCadence(streamInterval: input.interval)

		// 3. Slot clock while generating; none otherwise (pictures keep the pacer's targets).
		stoppedState = false
		let generating = cadence != .native && processor != nil
		if generating && method == .interpolate { updateClock(input) } else { clock = nil; addedLatency = 0 }

		if input.skip {
			// Pacer catch-up: keep as reference, don't show.
			lastPicture = pic
			if !isRepeat { lastNew = pic }
			return
		}

		if CACurrentMediaTime() - lastPublish > 0.25 { publish() }

		// 4. Routing.
		if isRepeat && generating && method == .extrapolate {
			// The slot of this repeat already got a predicted picture: drop it; otherwise show it (fallback).
			if extrapolatedFor != lastNew?.index || extrapolatedFor == nil {
				appendReal(input, index: idx)
				drain()
			}
			extrapolatedFor = nil
			lastPicture = pic
			return
		}
		if isRepeat {
			let lastSlotWaits = slots.last.map { $0.isGen && !$0.done && $0.next == nil } ?? false
			if lastSlotWaits, let w = slots.last {
				// Second repeat in a row (content below 30 fps): a 0.5-phase picture would be wrong for
				// either slot; show the pictures as they are.
				fallBack(w)
				appendReal(input, index: idx)
			} else if cadence == .fillRepeats && generating, let prev = lastNew {
				appendGen(prev: prev, fallback: input, slot: slotIndex(input.grid), index: idx)
			} else {
				appendReal(input, index: idx)
			}
			lastPicture = pic
			drain()
			return
		}

		// Cut? Histogram first (cheap); only a candidate is checked with motion estimation, so fast pans
		// and frames after a gap (explained by motion) are not taken for cuts.
		var motion: MotionExtrapolator.Motion?
		var isCut = lastNew == nil
		if let prev = lastNew, generating {
			let d = histDistance(prev.hist, hist)
			if d > cutHistDistance || method == .extrapolate {
				motion = extrapolator?.estimate(prev: prev.buffer, cur: input.buffer)
			}
			isCut = self.isCut(histDistance: d, motion: motion)
		}

		if generating && method == .extrapolate {
			extrapolateAfter(input: input, pic: pic, index: idx, motion: motion, isCut: isCut)
			lastPicture = pic
			lastNew = pic
			return
		}

		// Interpolation needs an 8-bit copy of the picture.
		if generating { pic.buffer8 = to8bit(input.buffer) }
		if cadence == .doubling && generating, let prev = lastNew, prev.index == lastPicture?.index {
			// Gap between two consecutive new pictures (30 fps stream, or 60 -> 120): the slot just
			// before this picture's. If frames were lost in between there is no single gap slot.
			let o = slotIndex(input.grid)
			if o - slotIndex(prev.input.grid) == 2 {
				appendGen(prev: prev, fallback: nil, slot: o - 1, index: idx)
			}
		}
		for slot in slots where slot.isGen && !slot.done && slot.next == nil {
			if isCut || input.discontinuity {
				if isCut { cutsSkipped += 1 }
				fallBack(slot) // never blend across a cut or a loss
			} else {
				slot.next = pic
			}
		}
		appendReal(input, index: idx)
		lastPicture = pic
		lastNew = pic
		kickInterpolation()
		drain()
	}

	// MARK: Extrapolation (no added delay)

	private var extrapolatedFor: Int?

	/// The real picture is emitted at once at its normal target; the predicted picture follows half a
	/// content interval later (doubling) or in the next stream slot (fill), if the motion is trustworthy.
	private func extrapolateAfter(input: Input, pic: Picture, index idx: Int, motion: MotionExtrapolator.Motion?, isCut: Bool) {
		appendReal(input, index: idx)
		drain()
		extrapolatedFor = nil
		guard let prev = lastNew, let ex = extrapolator else { return }
		if isCut || input.discontinuity || prev.input.discontinuity {
			if isCut { cutsSkipped += 1 }
			fallbacks += 1
			ex.resetHistory()
			return
		}
		guard let m = motion ?? ex.estimate(prev: prev.buffer, cur: input.buffer) else { fallbacks += 1; return }
		motionMs = m.ms
		let (ok, _) = Self.extrapolationAllowed(m)
		guard ok else {
			extrapolationRejected += 1
			fallbacks += 1
			return
		}
		let tOut = cadence == .doubling ? input.interval / 2 : input.interval
		let span = max(tOut, input.grid - prev.input.grid)
		let target = input.target + tOut
		let t0 = CACurrentMediaTime()
		guard t0 < target - commitMargin, let g = ex.warp(cur: input.buffer, prev: prev.buffer, factor: Float(tOut / span)) else {
			fallbacks += 1
			return
		}
		warpMs = (CACurrentMediaTime() - t0) * 1000
		guard CACurrentMediaTime() < target - commitMargin else { fallbacks += 1; return }
		emit?(GeneratedEmit(buffer: g, arrival: input.arrival, target: target, interval: tOut, kind: .generated, sourceIndex: idx))
		generated += 1
		genWindowCount += 1
		extrapolated += 1
		extrapolatedFor = idx
	}

	// MARK: Slot clock

	/// Output slot of a grid time.
	private func slotIndex(_ grid: Double) -> Int {
		guard let c = clock else { return 0 }
		return Int(((grid - c.anchorGrid) / c.periodOut).rounded())
	}

	/// Vsync time at which output slot `o` is shown.
	private func displayTime(_ o: Int) -> Double {
		guard let c = clock else { return 0 }
		return c.anchorDisplay + Double(o) * c.slotDur
	}

	private func vsyncInfo(fallbackRefresh: Double) -> (phase: Double, period: Double) {
		if let v = vsync?(), v.period > 0.002 { return v }
		return (0, fallbackRefresh)
	}

	private static func alignUp(_ t: Double, phase: Double, period: Double) -> Double {
		phase + (((t - phase) / period) - 1e-6).rounded(.up) * period
	}

	/// The delay (after the grid time) at which a real picture must be shown so the in-between picture
	/// before the next real one can be ready: jitter allowance (shared with pacing, not stacked) + half a
	/// content interval (= one output period) + interpolation time + commit margin. Capped so the added
	/// latency over the non-generating path stays within `maxAddedLatency`.
	private func neededDelay(_ i: Input, periodOut: Double) -> Double {
		let proc = procTimes.count > 4 ? procTimes.percentile(0.95, scratch: &procScratch) : 0.012
		let need = i.jitter + periodOut + proc + commitMargin
		let nonGenerating = i.pacerDelay
		return min(need, nonGenerating + maxAddedLatency)
	}

	/// Keeps the clock: created on entering generation, moved only in whole output slots — later at once
	/// when a real picture would miss its slot, earlier after 6 s with more than a slot of spare time.
	private func updateClock(_ i: Input) {
		let now = CACurrentMediaTime()
		let periodOut = cadence == .doubling ? i.interval / 2 : i.interval
		let v = vsyncInfo(fallbackRefresh: clock?.refresh ?? (1.0 / 120))
		let slotDur = max(1, (periodOut / v.period).rounded()) * v.period
		if clock == nil || abs(clock!.periodOut - periodOut) > 0.0005 || abs(clock!.slotDur - slotDur) > 0.0005 {
			let display = Self.alignUp(i.grid + neededDelay(i, periodOut: periodOut), phase: v.phase, period: v.period)
			clock = Clock(anchorGrid: i.grid, anchorDisplay: display, periodOut: periodOut, slotDur: slotDur, refresh: v.period,
			              windowStart: now, minSlack: .infinity, missed: false)
		}
		guard var c = clock else { return }
		let o = slotIndex(i.grid)
		let slack = displayTime(o) - commitMargin - now
		let contentInterval = 2 * periodOut
		if slack < 0 && -slack > 0.6 * contentInterval {
			// Late by most of a content interval: a frame the console did not deliver, or a network stall.
			// Moving the grid would add that much latency for good; show it late (one hitch) and keep the
			// grid. The pacer re-bases its grid when the console's timeline really slipped.
			lateReal += 1
		} else if slack < 0 {
			// This real picture would miss its slot: move the whole grid later by whole slots.
			let n = (-slack / c.slotDur).rounded(.up)
			c.anchorDisplay += n * c.slotDur
			c.missed = true
			lateReal += 1
			slotShifts += 1
			c.windowStart = now
			c.minSlack = .infinity
		} else {
			c.minSlack = min(c.minSlack, slack)
		}
		// Latency over budget, or comfortable for 3 s: one slot earlier.
		let delay = c.anchorDisplay + Double(o) * c.slotDur - i.grid
		let overBudget = delay - i.pacerDelay > maxAddedLatency + c.slotDur * 0.5
		if now - c.windowStart > 6 || overBudget {
			if overBudget || (!c.missed && c.minSlack > c.slotDur + 0.002) {
				c.anchorDisplay -= c.slotDur
				slotShifts += 1
			}
			c.windowStart = now
			c.minSlack = .infinity
			c.missed = false
		}
		clock = c
		// Added latency vs the non-generating path (which shows at its target + half a refresh on average).
		addedLatency = (displayTime(o) - i.grid) - (i.pacerDelay + c.refresh / 2)
	}

	private func noteGenSlack(_ slack: Double) {
		guard var c = clock else { return }
		if slack < 0 { c.missed = true } else { c.minSlack = min(c.minSlack, slack) }
		clock = c
	}

	private func appendReal(_ i: Input, index: Int) {
		var e = GeneratedEmit(buffer: i.buffer, arrival: i.arrival, target: i.target, interval: i.interval, kind: .real, sourceIndex: index)
		if let c = clock {
			let t = displayTime(slotIndex(i.grid))
			e.target = t
			e.interval = c.slotDur
			e.presentAt = t - c.refresh / 2 // first vsync at/after this is exactly the slot's vsync
		}
		slots.append(Slot(isGen: false, emit: e, target: e.target, interval: e.interval, index: index))
	}

	/// An in-between slot at output slot `o` (slot clock required).
	private func appendGen(prev: Picture, fallback: Input?, slot o: Int, index: Int) {
		guard let c = clock else {
			if let f = fallback { appendReal(f, index: index) }
			return
		}
		let t = displayTime(o)
		let slot = Slot(isGen: true, emit: nil, target: t, interval: c.slotDur, index: index)
		slot.prev = prev
		slot.fallback = fallback
		slot.presentAt = t - c.refresh / 2
		slots.append(slot)
		// Deadline: in the renderer `commitMargin` before the slot's vsync, else the fallback takes the slot.
		let wait = t - commitMargin - CACurrentMediaTime()
		queue.asyncAfter(deadline: .now() + max(0, wait)) { [weak self, weak slot] in
			guard let self, let slot, !slot.done else { return }
			self.noteGenSlack(-1)
			self.fallBack(slot)
			self.drain()
		}
	}

	/// No in-between picture for this slot: show the repeat (fill) or nothing (doubling).
	private func fallBack(_ slot: Slot) {
		guard !slot.done else { return }
		slot.done = true
		fallbacks += 1
		if let r = slot.fallback {
			slot.emit = GeneratedEmit(buffer: r.buffer, arrival: r.arrival, target: slot.target, interval: slot.interval, kind: .fallbackRepeat, sourceIndex: slot.index, presentAt: slot.presentAt)
		}
		publish()
	}

	private func drain() {
		while let head = slots.first, head.done {
			slots.removeFirst()
			if let e = head.emit { emit?(e) }
		}
	}

	private func flushSlots() {
		for s in slots where !s.done { fallBack(s) }
		drain()
	}

	private func kickInterpolation() {
		guard !interpolating,
		      let slot = slots.first(where: { $0.isGen && !$0.done && !$0.started && $0.next != nil }),
		      let prev = slot.prev?.buffer8, let next = slot.next?.buffer8
		else { return }
		slot.started = true
		interpolate(prev: prev, cur: next, slot: slot)
	}

	// MARK: Cadence

	private func updateCadence(streamInterval: Double) {
		let n = history.count
		guard n >= 12 else { cadence = .native; contentFPS = 1 / streamInterval; return }
		let recent = history.suffix(24)
		let newCount = recent.filter { $0 }.count
		contentFPS = Double(newCount) / Double(recent.count) / streamInterval
		// Isolated repeats (new, repeat, new) and the longest run of repeats.
		var isolated = 0, run = 0, maxRun = 0
		let arr = Array(recent)
		for i in 0..<arr.count {
			if !arr[i] { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
			if i > 0 && i < arr.count - 1 && !arr[i] && arr[i - 1] && arr[i + 1] { isolated += 1 }
		}
		let lowStream = streamInterval > 1.0 / 45 // a genuine 30 fps (or lower) stream
		let previous = cadence
		switch mode {
		case .off:
			cadence = .native
		case .to60, .to120:
			let allNewRecently = history.count >= 12 && history.suffix(12).allSatisfy { $0 }
			if lowStream {
				// A genuine 30 fps (or lower) stream: always the same path. Repeats in it are static
				// content, and interpolating two identical pictures is harmless (and costs nothing extra).
				cadence = .doubling
			} else if isolated >= 4 && maxRun <= 1 {
				cadence = .fillRepeats // ~30-59 fps content in a 60 fps stream
			} else if previous == .fillRepeats && !allNewRecently {
				// Stay until 12 new pictures in a row (true 60 fps content). A static picture (all repeats)
				// keeps the path, so pauses and menus don't toggle the latency.
				cadence = .fillRepeats
			} else if mode == .to120 && maxRun == 0 && history.suffix(12).allSatisfy({ $0 }) {
				cadence = .doubling // 60 fps content -> 120
			} else {
				cadence = .native // 60 fps content (to60), static picture, or below 30 fps
			}
		}
		if cadence != previous {
			NSLog("[PSVideo] frame generation: content %.0f fps, cadence %@ -> %@", contentFPS, previous.rawValue, cadence.rawValue)
			if cadence == .native { flushSlots() }
		}
	}

	private func histDistance(_ a: [Float], _ b: [Float]) -> Float {
		var d: Float = 0
		for i in 0..<min(a.count, b.count) { d += abs(a[i] - b[i]) }
		return d
	}

	// MARK: GPU work

	private func lumaTexture(_ pb: CVPixelBuffer) -> CVMetalTexture? {
		let tenBit = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			|| CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		var t: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, tenBit ? .r16Unorm : .r8Unorm,
		                                          CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &t)
		return t
	}

	/// Fraction of (1/4-resolution) luma samples that changed by more than `changedLevel` codes, and
	/// the normalised 32-bin luma histogram of `pb`.
	private func analyze(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (Float, [Float]) {
		guard let cur = lumaTexture(pb), let curT = CVMetalTextureGetTexture(cur),
		      let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder(),
		      let buf = device.makeBuffer(length: 34 * 4, options: .storageModeShared)
		else { return (1, []) }
		memset(buf.contents(), 0, 34 * 4)
		let prev = previous.flatMap { lumaTexture($0) }
		let prevT = prev.flatMap { CVMetalTextureGetTexture($0) } ?? curT
		var params = SIMD2<Float>(changedLevel / 255, previous == nil ? 0 : 1)
		enc.setComputePipelineState(analyzePSO)
		enc.setTexture(curT, index: 0)
		enc.setTexture(prevT, index: 1)
		enc.setBuffer(buf, offset: 0, index: 0)
		enc.setBytes(&params, length: 8, index: 1)
		let gw = curT.width / 4, gh = curT.height / 4
		enc.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
		enc.endEncoding()
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = (cur, prev)
		let p = buf.contents().bindMemory(to: UInt32.self, capacity: 34)
		let total = Float(gw * gh)
		let changed = Float(p[0]) / total
		let hist = (0..<32).map { Float(p[2 + $0]) / total }
		return (changed, hist)
	}

	/// 10-bit -> 8-bit 4:2:0 with triangular dither (the interpolator takes 8-bit only). 8-bit input is
	/// used as is.
	private func to8bit(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
		let fmt = CVPixelBufferGetPixelFormatType(pb)
		if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return pb }
		guard let pool8 else { return nil }
		var out: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool8, &out) == kCVReturnSuccess, let o = out else { return nil }
		CVBufferPropagateAttachments(pb, o)
		func tex(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) -> CVMetalTexture? {
			var t: CVMetalTexture?
			CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, b, nil, f,
			                                          CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
			return t
		}
		let t0 = CACurrentMediaTime()
		defer { convertMs = (CACurrentMediaTime() - t0) * 1000 }
		guard let sy = tex(pb, 0, .r16Unorm), let sc = tex(pb, 1, .rg16Unorm), let dy = tex(o, 0, .r8Unorm), let dc = tex(o, 1, .rg8Unorm),
		      let cmd = commandQueue.makeCommandBuffer() else { return nil }
		// Fixed dither pattern: a static pixel dithers identically in every frame, so the
		// interpolator and the static-overlay guard see it as static.
		var seed: UInt32 = 0x9E3779B9
		for (src, dst, pso) in [(sy, dy, dither8Y), (sc, dc, dither8C)] {
			let pass = MTLRenderPassDescriptor()
			pass.colorAttachments[0].texture = CVMetalTextureGetTexture(dst)
			pass.colorAttachments[0].loadAction = .dontCare
			pass.colorAttachments[0].storeAction = .store
			guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
			enc.setRenderPipelineState(pso)
			enc.setFragmentTexture(CVMetalTextureGetTexture(src), index: 0)
			enc.setFragmentBytes(&seed, length: 4, index: 0)
			enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			enc.endEncoding()
		}
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = (sy, sc, dy, dc)
		return o
	}

	/// Static-overlay guard: where the previous and next real pictures are identical in a 3x3
	/// neighbourhood (HUD, subtitles, minimap frame), take the real pixels instead of the interpolated
	/// ones, which drag static overlays along with the motion behind them. Returns a new buffer.
	private func protectStatic(prev: CVPixelBuffer, next: CVPixelBuffer, interp: CVPixelBuffer) -> CVPixelBuffer {
		guard staticGuard, let poolOut else { return interp }
		let t0 = CACurrentMediaTime()
		defer { guardMs = (CACurrentMediaTime() - t0) * 1000 }
		var out: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &out) == kCVReturnSuccess, let o = out,
		      let cmd = commandQueue.makeCommandBuffer() else { return interp }
		CVBufferPropagateAttachments(interp, o)
		func tex(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) -> CVMetalTexture? {
			var t: CVMetalTexture?
			CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, b, nil, f,
			                                          CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
			return t
		}
		var keep: [CVMetalTexture] = []
		for (plane, fmt, pso) in [(0, MTLPixelFormat.r8Unorm, protectY), (1, .rg8Unorm, protectC)] {
			guard let a = tex(prev, plane, fmt), let b = tex(next, plane, fmt), let i = tex(interp, plane, fmt), let d = tex(o, plane, fmt) else { return interp }
			keep += [a, b, i, d]
			let pass = MTLRenderPassDescriptor()
			pass.colorAttachments[0].texture = CVMetalTextureGetTexture(d)
			pass.colorAttachments[0].loadAction = .dontCare
			pass.colorAttachments[0].storeAction = .store
			guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return interp }
			enc.setRenderPipelineState(pso)
			enc.setFragmentTexture(CVMetalTextureGetTexture(a), index: 0)
			enc.setFragmentTexture(CVMetalTextureGetTexture(b), index: 1)
			enc.setFragmentTexture(CVMetalTextureGetTexture(i), index: 2)
			enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			enc.endEncoding()
		}
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = keep
		return o
	}

	private func ensureProcessor(_ w: Int, _ h: Int) {
		if processor != nil && processorSize == (w, h) { return }
		guard !settingUp else { return }
		guard w <= 1920, h <= 1080, w * h <= 1920 * 1080 else { return } // processor limit
		settingUp = true
		processor?.endSession()
		processor = nil
		setupQueue.async { [weak self] in
			// Model loading takes ~0.6 s: never on the frame path.
			guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else {
				self?.queue.async { self?.settingUp = false }
				return
			}
			let p = VTFrameProcessor()
			do { try p.startSession(configuration: cfg) } catch {
				NSLog("[PSVideo] frame interpolation session failed: %@", "\(error)")
				self?.queue.async { self?.settingUp = false }
				return
			}
			func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
				var a = attrs
				a[kCVPixelBufferWidthKey as String] = w
				a[kCVPixelBufferHeightKey as String] = h
				a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
				a[kCVPixelBufferMetalCompatibilityKey as String] = true
				a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
				var pl: CVPixelBufferPool?
				CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, a as CFDictionary, &pl)
				return pl
			}
			let p8 = pool(cfg.sourcePixelBufferAttributes), po = pool(cfg.destinationPixelBufferAttributes)
			self?.queue.async {
				guard let self else { return }
				self.settingUp = false
				guard self.mode != .off || self.diagnosticHold else { p.endSession(); return }
				self.processor = p
				self.processorSize = (w, h)
				self.pool8 = p8
				self.poolOut = po
				NSLog("[PSVideo] frame interpolation ready (%dx%d)", w, h)
			}
		}
	}

	private func interpolate(prev: CVPixelBuffer, cur: CVPixelBuffer, slot: Slot) {
		guard let proc = processor, let poolOut else { fallBack(slot); drain(); return }
		var dst: CVPixelBuffer?
		let t = slot.index
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &dst) == kCVReturnSuccess, let d = dst,
		      let fPrev = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t), timescale: 120)),
		      let fCur = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t + 2), timescale: 120)),
		      let fDst = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t + 1), timescale: 120)),
		      let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: fCur, previousFrame: fPrev, interpolationPhase: [0.5], destinationFrames: [fDst])
		else { fallBack(slot); drain(); return }
		CVBufferPropagateAttachments(cur, d)
		interpolating = true
		let started = CACurrentMediaTime()
		proc.process(parameters: params) { [weak self] _, error in
			let ms = CACurrentMediaTime() - started
			self?.queue.async {
				guard let self else { return }
				self.interpolating = false
				self.procTimes.push(ms, limit: 64)
				self.stats.update { $0.frameGenerationTimeMs = ms * 1000 }
				if !slot.done {
					if let error {
						NSLog("[PSVideo] frame interpolation failed: %@", "\(error)")
						self.fallBack(slot)
					} else {
						let out = self.protectStatic(prev: prev, next: cur, interp: d)
						slot.emit = GeneratedEmit(buffer: out, arrival: slot.next?.input.arrival ?? 0, target: slot.target,
						                          interval: slot.interval, kind: .generated, sourceIndex: slot.index, presentAt: slot.presentAt)
						self.noteGenSlack(slot.target - self.commitMargin - CACurrentMediaTime())
						slot.done = true
						self.generated += 1
						self.genWindowCount += 1
						self.publish()
					}
				}
				self.kickInterpolation()
				self.drain()
			}
		}
	}

	private var lastPublish = 0.0
	private var stoppedState = false

	private func publish() {
		let now = CACurrentMediaTime()
		lastPublish = now
		if genWindowStart == 0 { genWindowStart = now }
		var genFPS: Double?
		if now - genWindowStart >= 1 {
			genFPS = Double(genWindowCount) / (now - genWindowStart)
			genWindowStart = now
			genWindowCount = 0
		}
		let (m, c, cf, g, fb, cut, extra) = (mode, cadence, contentFPS, generated, fallbacks, cutsSkipped, addedLatency)
		let (shifts, late, conv, grd, stopped) = (slotShifts, lateReal, convertMs, guardMs, stoppedState)
		let (meth, rej, mms, wms) = (method, extrapolationRejected, motionMs, warpMs)
		stats.update { s in
			s.frameGeneration = m
			s.frameGenerationState = stopped ? "stopped" : c.rawValue
			s.frameGenerationSlotShifts = shifts
			s.frameGenerationLateReal = late
			s.frameGenerationConvertMs = conv
			s.frameGenerationGuardMs = grd
			s.frameGenerationMethod = meth
			s.frameGenerationRejectedMotion = rej
			s.frameGenerationMotionMs = mms
			s.frameGenerationWarpMs = wms
			s.contentFPS = cf
			s.framesGenerated = g
			s.frameGenerationFallbacks = fb
			s.frameGenerationCutsSkipped = cut
			s.frameGenerationAddedLatencyMs = extra * 1000
			if let genFPS { s.generatedFPS = genFPS }
		}
	}

	/// Diagnostics: interpolate the midpoint of two decoded pictures synchronously (any bit depth).
	func interpolateNow(prev: CVPixelBuffer, next: CVPixelBuffer) -> (CVPixelBuffer, Double)? {
		var result: (CVPixelBuffer, Double)?
		queue.sync {
			diagnosticHold = true
			ensureProcessor(CVPixelBufferGetWidth(prev), CVPixelBufferGetHeight(prev))
		}
		// Wait for the session (model load) if needed.
		for _ in 0..<300 where queue.sync(execute: { processor == nil }) { Thread.sleep(forTimeInterval: 0.01) }
		queue.sync {
			guard let proc = processor, let poolOut, let p8 = to8bit(prev), let n8 = to8bit(next) else { return }
			var dst: CVPixelBuffer?
			guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &dst) == kCVReturnSuccess, let d = dst,
			      let a = VTFrameProcessorFrame(buffer: p8, presentationTimeStamp: CMTime(value: 0, timescale: 120)),
			      let b = VTFrameProcessorFrame(buffer: n8, presentationTimeStamp: CMTime(value: 2, timescale: 120)),
			      let o = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: 1, timescale: 120)),
			      let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: b, previousFrame: a, interpolationPhase: [0.5], destinationFrames: [o])
			else { return }
			CVBufferPropagateAttachments(next, d)
			let sem = DispatchSemaphore(value: 0)
			let t0 = CACurrentMediaTime()
			var ok = false
			proc.process(parameters: params) { _, e in ok = e == nil; sem.signal() }
			sem.wait()
			if ok { result = (protectStatic(prev: p8, next: n8, interp: d), (CACurrentMediaTime() - t0) * 1000) }
		}
		return result
	}

	/// Diagnostics: interpolate at reduced resolution (w x h), scaled back to full size, to judge the
	/// quality / time trade-off. Returns the full-size picture and the total time (scale + interpolate +
	/// scale back) in ms.
	func interpolateScaledNow(prev: CVPixelBuffer, next: CVPixelBuffer, width w: Int, height h: Int) -> (CVPixelBuffer, Double)? {
		var out: (CVPixelBuffer, Double)?
		queue.sync {
			guard let p8 = to8bit(prev), let n8 = to8bit(next) else { return }
			if scaledProcessor == nil || scaledSize != (w, h) {
				guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else { return }
				let p = VTFrameProcessor()
				do { try p.startSession(configuration: cfg) } catch { NSLog("[PSVideo] scaled interpolation session: %@", "\(error)"); return }
				scaledSrcAttrs = cfg.sourcePixelBufferAttributes
				scaledDstAttrs = cfg.destinationPixelBufferAttributes
				scaledProcessor = p
				scaledSize = (w, h)
				var ts: VTPixelTransferSession?
				VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &ts)
				transfer = ts
			}
			guard let proc = scaledProcessor, let transfer else { return }
			func make(_ ww: Int, _ hh: Int, _ base: [String: Any] = [:]) -> CVPixelBuffer? {
				var a = base
				a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
				a[kCVPixelBufferMetalCompatibilityKey as String] = true
				var b: CVPixelBuffer?
				CVPixelBufferCreate(kCFAllocatorDefault, ww, hh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, a as CFDictionary, &b)
				return b
			}
			guard let sp = make(w, h, scaledSrcAttrs), let sn = make(w, h, scaledSrcAttrs), let sd = make(w, h, scaledDstAttrs),
			      let full = make(CVPixelBufferGetWidth(next), CVPixelBufferGetHeight(next)) else { return }
			let t0 = CACurrentMediaTime()
			VTPixelTransferSessionTransferImage(transfer, from: p8, to: sp)
			VTPixelTransferSessionTransferImage(transfer, from: n8, to: sn)
			guard let a = VTFrameProcessorFrame(buffer: sp, presentationTimeStamp: CMTime(value: 0, timescale: 120)),
			      let b = VTFrameProcessorFrame(buffer: sn, presentationTimeStamp: CMTime(value: 2, timescale: 120)),
			      let o = VTFrameProcessorFrame(buffer: sd, presentationTimeStamp: CMTime(value: 1, timescale: 120)),
			      let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: b, previousFrame: a, interpolationPhase: [0.5], destinationFrames: [o])
			else { return }
			let sem = DispatchSemaphore(value: 0)
			var ok = false
			proc.process(parameters: params) { _, e in
				ok = e == nil
				if let e { NSLog("[PSVideo] scaled interpolation failed: %@", "\(e)") }
				sem.signal()
			}
			sem.wait()
			guard ok else { return }
			VTPixelTransferSessionTransferImage(transfer, from: sd, to: full)
			CVBufferPropagateAttachments(next, full)
			out = (protectStatic(prev: p8, next: n8, interp: full), (CACurrentMediaTime() - t0) * 1000)
		}
		return out
	}
	private var scaledProcessor: VTFrameProcessor?
	private var scaledSize = (0, 0)
	private var scaledSrcAttrs: [String: Any] = [:]
	private var scaledDstAttrs: [String: Any] = [:]
	private var transfer: VTPixelTransferSession?

	/// Extrapolation is allowed only when the motion is trustworthy: motion explains the change
	/// (residual), and the field did not change much since the last interval (otherwise the prediction
	/// overshoots where motion stops or reverses).
	static func extrapolationAllowed(_ m: MotionExtrapolator.Motion) -> (Bool, String) {
		if m.residualRatio > 0.75 { return (false, "low confidence") }
		if !m.hasPreviousField { return (false, "no motion history") }
		if m.fieldChange > max(6, 0.5 * m.meanMotion) { return (false, "motion changing") }
		return (true, "ok")
	}

	/// A cut: the histogram changed a lot AND motion cannot explain the change (a fast pan or a frame
	/// after a gap changes the histogram little or is explained by motion).
	func isCut(histDistance d: Float, motion: MotionExtrapolator.Motion?) -> Bool {
		guard d > cutHistDistance else { return false }
		guard let m = motion else { return d > 1.0 }
		return m.residualRatio > 0.6 || d > 1.2
	}

	/// Diagnostics: extrapolate from (prev, cur) by `factor` (0.5 = half an interval ahead), synchronously.
	func extrapolateNow(prev: CVPixelBuffer, cur: CVPixelBuffer, factor: Float = 0.5, force: Bool = false)
		-> (picture: CVPixelBuffer?, decision: String, motion: MotionExtrapolator.Motion?, ms: Double)
	{
		queue.sync {
			let t0 = CACurrentMediaTime()
			guard let ex = extrapolator, let m = ex.estimate(prev: prev, cur: cur) else { return (nil, "unavailable", nil, 0) }
			let (ok, why) = Self.extrapolationAllowed(m)
			guard ok || force else { return (nil, why, m, (CACurrentMediaTime() - t0) * 1000) }
			let pic = ex.warp(cur: cur, prev: prev, factor: factor)
			return (pic, ok ? "ok" : "forced (\(why))", m, (CACurrentMediaTime() - t0) * 1000)
		}
	}

	/// Diagnostics: the analysis numbers for two pictures.
	func analyzeNow(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (changed: Float, hist: [Float]) {
		queue.sync { analyze(pb, previous: previous) }
	}

	func histogramDistance(_ a: [Float], _ b: [Float]) -> Float { histDistance(a, b) }

	static let shaders = """
	#include <metal_stdlib>
	using namespace metal;

	kernel void psv_analyze(texture2d<float, access::read> cur [[texture(0)]],
	                        texture2d<float, access::read> prev [[texture(1)]],
	                        device atomic_uint *out [[buffer(0)]],
	                        constant float2 &p [[buffer(1)]],
	                        uint2 gid [[thread_position_in_grid]]) {
		uint2 pos = gid * 4 + 1;
		if (pos.x >= cur.get_width() || pos.y >= cur.get_height()) return;
		float c = cur.read(pos).r;
		float d = abs(c - prev.read(pos).r);
		if (p.y > 0.5 && d > p.x) atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
		uint bin = min(31u, uint(c * 32.0));
		atomic_fetch_add_explicit(&out[2 + bin], 1u, memory_order_relaxed);
	}

	struct FGOut { float4 position [[position]]; float2 uv; };
	vertex FGOut psv_fg_vertex(uint vid [[vertex_id]]) {
		float2 q = float2((vid << 1) & 2, vid & 2);
		FGOut o;
		o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(q.x, 1.0 - q.y);
		return o;
	}

	float hash(uint2 p, uint s) {
		uint h = p.x * 1973u + p.y * 9277u + s * 26699u;
		h = (h ^ (h >> 13)) * 0x5bd1e995u;
		return float(h & 0xffffu) / 65535.0;
	}

	// 10-bit code (top bits of 16) -> 8-bit with triangular-PDF dither of +-1 LSB.
	fragment float psv_dither_y(FGOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant uint &seed [[buffer(0)]]) {
		constexpr sampler s(filter::nearest);
		uint2 p = uint2(in.position.xy);
		float v = src.sample(s, in.uv).r * (65535.0 / 256.0); // 10-bit code / 4
		float n = hash(p, seed) + hash(p, seed + 7u) - 1.0;
		return clamp(floor(v + 0.5 + n * 0.5), 0.0, 255.0) / 255.0;
	}

	// Max |prev - next| over a 3x3 neighbourhood below ~3 codes: static -> real pixel.
	fragment float psv_protect_y(FGOut in [[stage_in]], texture2d<float, access::read> a [[texture(0)]],
	                             texture2d<float, access::read> b [[texture(1)]], texture2d<float, access::read> i [[texture(2)]]) {
		int2 p = int2(in.position.xy);
		int2 mx = int2(a.get_width() - 1, a.get_height() - 1);
		float m = 0.0;
		for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
			uint2 q = uint2(clamp(p + int2(dx, dy), int2(0), mx));
			m = max(m, abs(a.read(q).r - b.read(q).r));
		}
		uint2 c = uint2(p);
		return m < 3.5 / 255.0 ? 0.5 * (a.read(c).r + b.read(c).r) : i.read(c).r;
	}

	fragment float2 psv_protect_c(FGOut in [[stage_in]], texture2d<float, access::read> a [[texture(0)]],
	                              texture2d<float, access::read> b [[texture(1)]], texture2d<float, access::read> i [[texture(2)]]) {
		int2 p = int2(in.position.xy);
		int2 mx = int2(a.get_width() - 1, a.get_height() - 1);
		float m = 0.0;
		for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
			uint2 q = uint2(clamp(p + int2(dx, dy), int2(0), mx));
			float2 d = abs(a.read(q).rg - b.read(q).rg);
			m = max(m, max(d.x, d.y));
		}
		uint2 c = uint2(p);
		return m < 3.5 / 255.0 ? 0.5 * (a.read(c).rg + b.read(c).rg) : i.read(c).rg;
	}

	fragment float2 psv_dither_c(FGOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant uint &seed [[buffer(0)]]) {
		constexpr sampler s(filter::nearest);
		uint2 p = uint2(in.position.xy);
		float2 v = src.sample(s, in.uv).rg * (65535.0 / 256.0);
		float2 n = float2(hash(p, seed + 3u) + hash(p, seed + 11u) - 1.0, hash(p, seed + 5u) + hash(p, seed + 13u) - 1.0);
		return clamp(floor(v + 0.5 + n * 0.5), 0.0, 255.0) / 255.0;
	}
	"""
}

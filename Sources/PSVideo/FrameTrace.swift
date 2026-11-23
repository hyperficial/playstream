import Foundation
import QuartzCore

/// Why a generation slot produced what it produced (also the keys of `VideoStats.frameGenerationReasons`).
enum TraceReason: Int, CaseIterable {
	case none = 0
	case generated
	/// The in-between picture was not ready by the slot's deadline. value = how late (ms) / limit = stage
	/// (0 = still waiting for the next real picture, 1 = interpolating, 2 = in the queue behind another).
	case deadlineMissed
	case cut                     // value = histogram distance, limit = residual ratio
	case loss                    // frames lost / repaired / decode error between the two pictures
	case lowConfidence           // value = residual ratio, limit = threshold
	case motionChanging          // value = field change (px), limit = allowed change (px)
	case noMotionHistory         // first pair after a reset / cut
	case staticContent           // the slot's picture is a repeat of the previous one: shown as is
	case budgetExceeded          // value = needed delay (ms), limit = allowed (ms)
	case interpolatorNotReady    // VideoToolbox session still loading
	case interpolationFailed     // VideoToolbox returned an error
	case runOfRepeats            // two or more repeats in a row (content below 30 fps)
	case noGapSlot               // pictures not exactly one output slot apart (value = slot distance)
	case processingTooLate       // extrapolation finished after its deadline; value = ms late
	case noPrevious              // no previous real picture yet
	case cancelled               // generation switched off / mode change / stop
	// Events.
	case pacerRebase             // value = lateness (ms) of the slipped frames
	case pacerLate               // value = lateness (ms)
	case slotShiftLater          // value = slots
	case slotShiftEarlier
	case cadenceChange           // value = new cadence (0 native, 1 fill, 2 doubling), limit = content fps
	case keepAlive               // last picture re-presented to keep the panel in range; value = ms since the last present
	case presentModeChange       // value = new present.mode

	var name: String {
		switch self {
		case .none: return "none"
		case .generated: return "generated"
		case .deadlineMissed: return "deadline_missed"
		case .cut: return "cut"
		case .loss: return "loss"
		case .lowConfidence: return "low_confidence"
		case .motionChanging: return "motion_changing"
		case .noMotionHistory: return "no_motion_history"
		case .staticContent: return "static_content"
		case .budgetExceeded: return "budget_exceeded"
		case .interpolatorNotReady: return "interpolator_not_ready"
		case .interpolationFailed: return "interpolation_failed"
		case .runOfRepeats: return "run_of_repeats"
		case .noGapSlot: return "no_gap_slot"
		case .processingTooLate: return "processing_too_late"
		case .noPrevious: return "no_previous"
		case .cancelled: return "cancelled"
		case .pacerRebase: return "pacer_rebase"
		case .pacerLate: return "pacer_late"
		case .slotShiftLater: return "slot_shift_later"
		case .slotShiftEarlier: return "slot_shift_earlier"
		case .cadenceChange: return "cadence_change"
		case .keepAlive: return "keep_alive"
		case .presentModeChange: return "present_mode_change"
		}
	}
}

/// One picture, generation slot or event. Times are host seconds (CACurrentMediaTime base); NaN = unset.
struct TraceRecord {
	enum Kind: UInt8 { case frame = 0, slot = 1, event = 2 }
	enum Outcome: UInt8 { case pending = 0, generated = 1, fallback = 2, rejected = 3 }
	enum Shown: UInt8 { case unknown = 0, real = 1, generated = 2, fallbackRepeat = 3, notShown = 4, skipped = 5 }
	struct Flags: OptionSet { let rawValue: UInt16
		static let late = Flags(rawValue: 1), skip = Flags(rawValue: 2), isRepeat = Flags(rawValue: 4)
		static let discontinuity = Flags(rawValue: 8), keyframe = Flags(rawValue: 16), outlier = Flags(rawValue: 32)
	}

	var id = 0
	var kind = Kind.frame
	var seq = -1            // stream frame number (decode order); slot: the real picture that closes the gap
	var time = Double.nan   // when the record was made
	// Frame.
	var arrival = Double.nan
	var submitted = Double.nan    // handed to VTDecompressionSession
	var decoded = Double.nan
	var target = Double.nan       // pacer target (or slot-clock time)
	var delayMs = Double.nan      // pacer delay in force
	var presentAt = Double.nan    // requested present time
	var committed = Double.nan    // handed to the GPU / compositor
	var presented = Double.nan    // on glass (Metal path, when on screen)
	var refreshes = Double.nan    // how many refreshes it stayed on screen
	var flags = Flags()
	var shown = Shown.unknown
	// Slot.
	var method: UInt8 = 0         // 1 interpolate, 2 extrapolate
	var outcome = Outcome.pending
	var reason = TraceReason.none
	var value = Double.nan
	var limit = Double.nan
	var convertMs = Double.nan, motionMs = Double.nan, interpMs = Double.nan, warpMs = Double.nan, guardMs = Double.nan
	var slackMs = Double.nan      // deadline - completion (ms); negative = missed
}

/// Fixed-size ring of trace records, always on. ~16k records = several minutes at 30 fps, well over
/// 60 s at 60 fps with generation (about 3 records per stream frame).
final class FrameTrace: @unchecked Sendable {
	static let capacity = 16384
	private let lock = UnfairLock()
	private var ring = [TraceRecord](repeating: TraceRecord(), count: FrameTrace.capacity)
	private var nextID = 1

	/// Adds a record and returns its id (for later updates).
	@discardableResult
	func add(_ r: TraceRecord) -> Int {
		lock.withLock {
			var r = r
			r.id = nextID
			if r.time.isNaN { r.time = CACurrentMediaTime() }
			ring[nextID % Self.capacity] = r
			nextID += 1
			return r.id
		}
	}

	/// Updates a record if it is still in the ring.
	func update(_ id: Int, _ body: (inout TraceRecord) -> Void) {
		guard id > 0 else { return }
		lock.withLock {
			let i = id % Self.capacity
			if ring[i].id == id { body(&ring[i]) }
		}
	}

	func event(_ reason: TraceReason, value: Double = .nan, limit: Double = .nan, seq: Int = -1) {
		var r = TraceRecord()
		r.kind = .event
		r.reason = reason
		r.value = value
		r.limit = limit
		r.seq = seq
		add(r)
	}

	func snapshot(lastSeconds: Double) -> [TraceRecord] {
		let now = CACurrentMediaTime()
		return lock.withLock {
			var out: [TraceRecord] = []
			let first = max(1, nextID - Self.capacity)
			for id in first..<nextID {
				let r = ring[id % Self.capacity]
				if r.id == id && now - r.time <= lastSeconds { out.append(r) }
			}
			return out
		}
	}

	static let schemaDescription: [String: String] = [
		"type": "frame | slot | event",
		"id": "record id (increasing)",
		"seq": "stream frame number in decode order; for a slot, the real picture that closes the gap",
		"t": "record creation time, host seconds (CACurrentMediaTime)",
		"arrival": "frame arrival (host s)", "submitted": "handed to the decoder (host s)", "decoded": "decoder output (host s)",
		"decode_ms": "decoder submit-to-output latency (ms)",
		"target": "pacer target or slot-clock time (host s)", "delay_ms": "pacer delay in force (ms)",
		"present_at": "requested present time (host s)", "committed": "handed to the GPU (host s)",
		"presented": "on glass (host s, Metal path in a window)", "refreshes": "refreshes it stayed on screen",
		"late": "pacer: arrived after its slot", "skip": "pacer: decoded, not shown (catch-up / burst)",
		"repeat": "same picture as the previous one (changed < fg.repeatFraction)",
		"changed": "frame generation only: fraction of 1/4-res luma samples that changed by > fg.repeatChangedLevel codes vs the previous picture", "discontinuity": "loss / repair / decode error before it",
		"outlier": "pacer: late by a whole interval (missed console frame / stall)",
		"shown": "real | generated | fallback_repeat | not_shown | skipped",
		"method": "interpolate | extrapolate", "outcome": "generated | fallback | rejected",
		"reason": "see TraceReason names", "value": "reason-specific value", "limit": "reason-specific limit",
		"convert_ms": "10->8-bit conversion", "motion_ms": "motion estimation", "interp_ms": "interpolator",
		"warp_ms": "extrapolation warp", "guard_ms": "overlay guard", "slack_ms": "deadline - completion (ms)",
	]

	/// JSON Lines: a schema line (with the tunables in force), then one object per record.
	func write(to url: URL, lastSeconds: Double, tunables: [String: Double], extra: [String: Any]) throws -> Int {
		let recs = snapshot(lastSeconds: lastSeconds)
		var out = Data()
		var head: [String: Any] = ["schema": "playstream.video.trace.v1", "fields": Self.schemaDescription, "tunables": tunables,
		                           "written_at_host_s": CACurrentMediaTime(), "records": recs.count]
		for (k, v) in extra { head[k] = v }
		out.append(try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys]))
		out.append(0x0A)
		for r in recs {
			var o: [String: Any] = ["id": r.id, "seq": r.seq, "t": r.time]
			func put(_ k: String, _ v: Double, scale: Double = 1) { if v.isFinite { o[k] = (v * scale * 1e6).rounded() / 1e6 } }
			switch r.kind {
			case .frame:
				o["type"] = "frame"
				put("arrival", r.arrival); put("submitted", r.submitted); put("decoded", r.decoded)
				if r.submitted.isFinite && r.decoded.isFinite { put("decode_ms", (r.decoded - r.submitted) * 1000) }
				put("target", r.target); put("delay_ms", r.delayMs)
				put("present_at", r.presentAt); put("committed", r.committed); put("presented", r.presented); put("refreshes", r.refreshes)
				put("changed", r.value)
				if r.flags.contains(.late) { o["late"] = true }
				if r.flags.contains(.skip) { o["skip"] = true }
				if r.flags.contains(.isRepeat) { o["repeat"] = true }
				if r.flags.contains(.discontinuity) { o["discontinuity"] = true }
				if r.flags.contains(.keyframe) { o["keyframe"] = true }
				if r.flags.contains(.outlier) { o["outlier"] = true }
			case .slot:
				o["type"] = "slot"
				o["method"] = r.method == 1 ? "interpolate" : "extrapolate"
				o["outcome"] = ["pending", "generated", "fallback", "rejected"][Int(r.outcome.rawValue)]
				o["reason"] = r.reason.name
				put("value", r.value); put("limit", r.limit); put("target", r.target)
				put("present_at", r.presentAt); put("committed", r.committed); put("presented", r.presented); put("refreshes", r.refreshes)
				put("convert_ms", r.convertMs); put("motion_ms", r.motionMs); put("interp_ms", r.interpMs)
				put("warp_ms", r.warpMs); put("guard_ms", r.guardMs); put("slack_ms", r.slackMs)
			case .event:
				o["type"] = "event"
				o["reason"] = r.reason.name
				put("value", r.value); put("limit", r.limit)
			}
			if r.shown != .unknown { o["shown"] = ["unknown", "real", "generated", "fallback_repeat", "not_shown", "skipped"][Int(r.shown.rawValue)] }
			out.append(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
			out.append(0x0A)
		}
		try out.write(to: url, options: .atomic)
		return recs.count
	}
}

import PSContracts
import PSVideo
import SwiftUI

/// One point of overlay history, taken a few times a second.
struct StatsSample {
	/// Pictures put on screen per second, real plus generated.
	var outputFPS: Double
	/// Average and worst on-screen time of a picture in the sampling window, ms.
	var frameTimeMs: Double
	var frameTimeMaxMs: Double
	/// Frame arrival to on screen, ms (nil where the renderer cannot measure it).
	var latencyMs: Double?
	var bitrateMbps: Double
	/// Longest gap between frame arrivals in the pipeline's recent window, ms.
	var arrivalGapMs: Double
}

enum StatsLevel: Int {
	case off = 0
	case compact = 1
	case full = 2

	var next: StatsLevel { StatsLevel(rawValue: (rawValue + 1) % 3) ?? .off }
}

struct StatsOverlay: View {
	let stats: StreamController.LiveStats
	let history: [StatsSample]
	let profile: StreamProfile
	let level: StatsLevel

	private var video: VideoStats { stats.video }
	private var latest: StatsSample? { history.last }

	/// The frame time the output is aiming for (60 fps output when generating up to 60, etc.).
	private var targetFrameTimeMs: Double {
		let fps = max(latest?.outputFPS ?? Double(profile.fps), 1)
		let nominal: Double = fps > 90 ? 120 : (fps > 45 ? 60 : 30)
		return 1000 / nominal
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			headline
			if video.recentPresentedIntervalsMs.count > 8 {
				// One point per picture actually shown: the real frame-time trace.
				graph(
					title: "Frame time (per frame)",
					values: video.recentPresentedIntervalsMs.suffix(StreamController.historyLength).map(Double.init),
					secondary: nil,
					reference: targetFrameTimeMs,
					ceiling: targetFrameTimeMs * 3,
					trailing: String(format: "%.1f ms  99%% %.1f  worst %.1f", latest?.frameTimeMs ?? 0, video.frameTimeP99Ms ?? 0, video.frameTimeMaxMs ?? 0)
				)
			} else {
				graph(
					title: "Frame time",
					values: history.map(\.frameTimeMaxMs),
					secondary: history.map(\.frameTimeMs),
					reference: targetFrameTimeMs,
					ceiling: targetFrameTimeMs * 3,
					trailing: latest.map { String(format: "%.1f ms  worst %.1f", $0.frameTimeMs, $0.frameTimeMaxMs) } ?? "-"
				)
			}
			if level == .full, video.recentArrivalIntervalsMs.count > 8 {
				graph(
					title: "Network arrival (per frame)",
					values: video.recentArrivalIntervalsMs.suffix(StreamController.historyLength).map(Double.init),
					secondary: nil,
					reference: 1000 / max(video.streamFPS, 1),
					ceiling: 3000 / max(video.streamFPS, 1),
					trailing: String(format: "longest gap %.0f ms", video.arrivalMaxGapMs)
				)
			}
			if level == .full {
				graph(
					title: "Delay to screen",
					values: history.map { $0.latencyMs ?? 0 },
					secondary: nil,
					reference: nil,
					ceiling: 120,
					trailing: latest?.latencyMs.map { String(format: "%.0f ms", $0) } ?? "not measured on this renderer"
				)
				graph(
					title: "Bitrate",
					values: history.map(\.bitrateMbps),
					secondary: nil,
					reference: nil,
					ceiling: max(Double(profile.bitrateKbps) / 1000, (history.map(\.bitrateMbps).max() ?? 1) * 1.1),
					trailing: String(format: "%.1f of %.0f Mbit/s", stats.session.measuredBitrate / 1_000_000, Double(profile.bitrateKbps) / 1000)
				)
				details
			}
		}
		.font(.caption.monospacedDigit())
		.foregroundStyle(.white)
		.padding(12)
		.frame(width: 330, alignment: .leading)
		.background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
	}

	// MARK: Headline

	private var headline: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text(String(format: "%.0f", latest?.outputFPS ?? 0))
					.font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
				Text("fps").foregroundStyle(.white.opacity(0.6))
				Spacer()
				Text(String(format: "%.1f", latest?.frameTimeMs ?? 0))
					.font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
				Text("ms").foregroundStyle(.white.opacity(0.6))
			}
			HStack(spacing: 6) {
				if video.frameGeneration != .off {
					chip(String(format: "game %.0f", video.contentFPS))
					chip(String(format: "+%.0f generated", video.generatedFPS), highlighted: video.generatedFPS > 1)
				} else {
					chip(String(format: "stream %.0f", video.decodedFPS))
				}
				chip("\(video.width)×\(video.height)")
				chip(video.hdrActive ? "HDR" : "SDR")
				if video.activeUpscaler != .off { chip(upscalerName) }
			}
		}
	}

	private var upscalerName: String {
		switch video.activeUpscaler {
		case .off: return "no upscaling"
		case .bicubic: return "Bicubic"
		case .metalFXSpatial: return "MetalFX"
		case .fsr1: return "FSR 1"
		}
	}

	private func chip(_ text: String, highlighted: Bool = false) -> some View {
		Text(text)
			.font(.caption2.monospacedDigit())
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(highlighted ? Color.green.opacity(0.35) : Color.white.opacity(0.14), in: Capsule())
	}

	// MARK: Graphs

	private func graph(title: String, values: [Double], secondary: [Double]?, reference: Double?, ceiling: Double, trailing: String) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack {
				Text(title).foregroundStyle(.white.opacity(0.6))
				Spacer()
				Text(trailing)
			}
			let capacity = StreamController.historyLength
			Canvas { context, size in
				let top = max(ceiling, 1)
				func path(_ series: [Double]) -> Path {
					var path = Path()
					guard series.count > 1 else { return path }
					let step = size.width / CGFloat(capacity - 1)
					let offset = CGFloat(capacity - series.count) * step
					for (index, value) in series.enumerated() {
						let y = size.height - CGFloat(min(max(value, 0), top) / top) * size.height
						let point = CGPoint(x: offset + CGFloat(index) * step, y: y)
						if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
					}
					return path
				}
				if let reference, reference < top {
					let y = size.height - CGFloat(reference / top) * size.height
					var line = Path()
					line.move(to: CGPoint(x: 0, y: y))
					line.addLine(to: CGPoint(x: size.width, y: y))
					context.stroke(line, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
				}
				// Worst-case series: orange where it strays, drawn first so the average sits on top.
				context.stroke(path(values), with: .color(secondary == nil ? .green : .orange.opacity(0.9)), lineWidth: 1.2)
				if let secondary {
					context.stroke(path(secondary), with: .color(.green), lineWidth: 1.4)
				}
			}
			.frame(height: 34)
			.background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
		}
	}

	// MARK: Details

	private var details: some View {
		VStack(alignment: .leading, spacing: 3) {
			row("Network", String(format: "loss %.1f%%  rtt %.0f ms  jitter %.1f ms", stats.session.packetLoss * 100, stats.session.rttMilliseconds, video.arrivalJitterP95Ms))
			row("Arrival", String(format: "longest gap %.0f ms", video.arrivalMaxGapMs))
			row("Frames", "lost \(video.framesLostInNetwork)  dropped \(video.framesDropped)  late \(video.framesLate)  skipped \(video.framesSkipped)")
			row("Pacing", video.pacingMode == .off ? "off" : String(format: "hold %.0f ms", video.playoutDelayMs))
			if video.frameGeneration != .off {
				row("Frame gen", "\(video.frameGenerationMethod)  made \(video.framesGenerated)  skipped \(video.frameGenerationFallbacks + video.frameGenerationRejectedMotion)")
			}
			if let decode = video.decodeTimeAvgMs, let gpu = video.renderGPUTimeAvgMs {
				row("Work", String(format: "decode %.1f ms  render %.1f ms", decode, gpu))
			}
			if video.activeUpscaler != .off {
				row("Upscale", "to \(video.upscaleOutputWidth)×\(video.upscaleOutputHeight)")
			}
			if let audio = stats.audio {
				row("Audio", String(format: "buffer %.0f/%.0f ms  out %.0f ms  dry %d", audio.bufferedMs, audio.targetMs, audio.outputLatencyMs, audio.underruns))
				if audio.shaping != "off" {
					row("Sound", String(format: "%@  holding down %.0f dB", audio.shaping, audio.dynamicsReductionDb))
				}
			}
		}
	}

	private func row(_ title: String, _ value: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(title).foregroundStyle(.white.opacity(0.6)).frame(width: 62, alignment: .leading)
			Text(value)
		}
	}
}

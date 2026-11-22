import AudioToolbox
import CoreAudio
import Foundation
import os
import PSContracts

public struct AudioPipelineConfiguration: Sendable {
	/// Mean amount of audio to keep buffered, in milliseconds. Playback starts once this much has arrived.
	public var targetBufferMs: Double = 35
	/// When the buffer exceeds target + this, it jumps back to target with a short crossfade.
	public var maxExcessMs: Double = 60
	/// I/O buffer size requested from the output device, in frames (clamped to what the hardware allows).
	public var preferredIOBufferFrames: Int = 128
	/// No audio device: the caller pulls samples with `renderHeadless`. For tests.
	public var headless: Bool = false

	public init() {}
}

public struct AudioPipelineStats: Sendable {
	/// Audio currently queued ahead of the render position.
	public var bufferedMs: Double
	public var targetMs: Double
	/// False while priming / after an underrun (output is silent).
	public var isPlaying: Bool
	/// Times the buffer ran dry during playback.
	public var underruns: Int
	/// Chunks dropped because the ring was full (consumer stalled).
	public var overruns: Int
	/// Times the buffer was too full and was skipped back to target.
	public var skips: Int
	public var chunksReceived: Int
	/// Current playback-rate trim used to track the sender's clock, in parts per million.
	public var driftTrimPPM: Int
	public var outputDeviceName: String
	/// Nominal sample rate of the output device (0 if none).
	public var outputSampleRate: Double
	/// Device I/O buffer in frames, as granted by the hardware.
	public var ioBufferFrames: Int
	/// Estimated delay from our render callback to the sound leaving the device (device + stream + safety + I/O buffer).
	public var outputLatencyMs: Double
	/// bufferedMs + outputLatencyMs.
	public var totalLatencyMs: Double
	/// How many times the output has been (re)built, including the first.
	public var outputBuilds: Int
}

/// Plays the PS5 audio stream with a low-latency jitter buffer.
///
///     let audio = AudioPipeline()
///     audio.pcmTap = recorder            // optional
///     session.audioSink = audio          // core calls configure / receive / stop
///     audio.volume = 0.8                 // main thread, any time
///
public final class AudioPipeline: AudioStreamSink {
	public let configuration: AudioPipelineConfiguration

	/// 0...1, main thread. Changes are ramped (no zipper noise).
	public var volume: Float = 1 {
		didSet {
			let v = min(1, max(0, volume.isNaN ? 0 : volume))
			core.volumeBits.store(v.bitPattern, ordering: .relaxed)
		}
	}
	public var isMuted: Bool = false {
		didSet { core.muted.store(isMuted, ordering: .relaxed) }
	}
	/// Called on the network thread for every incoming chunk, with `mach_absolute_time()` at arrival.
	/// Set before the stream starts. The tap gets `pcmAudioDidConfigure` on the network thread before its first chunk.
	public weak var pcmTap: PCMAudioTap?

	/// Live-adjustable target buffer fill.
	public var targetBufferMs: Double {
		get { Double(core.targetMicros.load(ordering: .relaxed)) / 1000 }
		set { core.targetMicros.store(Int(max(5, min(500, newValue)) * 1000), ordering: .relaxed) }
	}

	/// Diagnostic lines (device changes, rebuilds, failures). Called on an internal queue.
	public var logHandler: (@Sendable (String) -> Void)?

	// MARK: State

	private let core = AudioRenderCore()
	private let control = DispatchQueue(label: "playstream.audio.control", qos: .userInteractive)
	private let log = Logger(subsystem: "playstream", category: "audio")

	// Producer-thread state.
	private var channels = 2
	private var tapNotifiedFor: ObjectIdentifier?
	private var tapNotifiedFormat = (channels: 0, rate: 0)
	private var configured = false

	// Control-queue state.
	private var wanted = false
	private var unit: AudioUnit?
	private var deviceID: AudioDeviceID = kAudioObjectUnknown
	private var systemListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
	private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
	private var pendingRebuild: DispatchWorkItem?
	private var watchdog: DispatchSourceTimer?
	private var lastHeartbeat = -1
	private var stalledTicks = 0
	private var builds = 0

	private let infoLock = NSLock()
	private var deviceFacts = CA.DeviceFacts()
	private var buildCount = 0

	public init(configuration: AudioPipelineConfiguration = AudioPipelineConfiguration()) {
		self.configuration = configuration
		core.targetMicros.store(Int(configuration.targetBufferMs * 1000), ordering: .relaxed)
		core.maxExcessMicros.store(Int(configuration.maxExcessMs * 1000), ordering: .relaxed)
	}

	deinit {
		// No other thread can be inside a method (each holds a strong reference), so no queue hop,
		// which could deadlock if the last release happens on the control queue.
		stopLocked()
	}

	// MARK: Stats

	public var stats: AudioPipelineStats {
		let w = core.writeIdx.load(ordering: .acquiring)
		let r = core.readIdx.load(ordering: .acquiring)
		let rate = Double(max(1, core.srcRate.load(ordering: .relaxed)))
		let buffered = Double(max(0, min(AudioRenderCore.capacity, w - r))) / rate * 1000
		infoLock.lock()
		let facts = deviceFacts
		let builds = buildCount
		infoLock.unlock()
		let outLat = facts.sampleRate > 0 ? Double(facts.latencyFrames) / facts.sampleRate * 1000 : 0
		return AudioPipelineStats(
			bufferedMs: buffered,
			targetMs: targetBufferMs,
			isPlaying: core.playingFlag.load(ordering: .relaxed),
			underruns: core.underruns.load(ordering: .relaxed),
			overruns: core.overruns.load(ordering: .relaxed),
			skips: core.skips.load(ordering: .relaxed),
			chunksReceived: core.chunksIn.load(ordering: .relaxed),
			driftTrimPPM: core.adjPPM.load(ordering: .relaxed),
			outputDeviceName: facts.name,
			outputSampleRate: facts.sampleRate,
			ioBufferFrames: facts.bufferFrames,
			outputLatencyMs: outLat,
			totalLatencyMs: buffered + outLat,
			outputBuilds: builds
		)
	}

	// MARK: AudioStreamSink (network thread)

	public func audioStreamDidConfigure(channels: Int, sampleRate: Int) {
		let ch = max(1, channels)
		let rate = max(8000, min(192_000, sampleRate))
		self.channels = ch
		configured = true
		control.sync {
			let changed = core.srcRate.load(ordering: .relaxed) != rate
			if wanted && !changed && unit != nil { return }
			// Output (if any) must be stopped while the source rate changes.
			if wanted { teardownOutputLocked() }
			core.srcRate.store(rate, ordering: .relaxed)
			startLocked()
		}
		if let tap = pcmTap {
			tapNotifiedFor = ObjectIdentifier(tap)
			tapNotifiedFormat = (ch, rate)
			tap.pcmAudioDidConfigure(channels: ch, sampleRate: rate)
		}
	}

	public func audioStreamDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int) {
		let arrival = mach_absolute_time()
		guard frameCount > 0 else { return }
		let ch = pcm.count / frameCount
		guard ch > 0 else { return }
		if !configured || ch != channels {
			audioStreamDidConfigure(channels: ch, sampleRate: core.srcRate.load(ordering: .relaxed))
		}
		if let tap = pcmTap {
			if tapNotifiedFor != ObjectIdentifier(tap) {
				tapNotifiedFor = ObjectIdentifier(tap)
				tap.pcmAudioDidConfigure(channels: channels, sampleRate: core.srcRate.load(ordering: .relaxed))
			}
			tap.pcmAudioDidReceive(pcm: pcm, frameCount: frameCount, hostTime: arrival)
		}
		if core.active.load(ordering: .acquiring) {
			_ = core.write(pcm, frames: frameCount, channels: channels)
		}
	}

	public func audioStreamDidStop() {
		control.sync { stopLocked() }
		configured = false
		tapNotifiedFor = nil
	}

	/// Headless mode only: pull `frameCount` stereo float frames as the audio device would.
	public func renderHeadless(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
		core.render(out, frames: frameCount)
	}

	// MARK: Control queue

	private func emit(_ message: String) {
		log.notice("\(message, privacy: .public)")
		logHandler?(message)
	}

	private func startLocked() {
		wanted = true
		if systemListeners.isEmpty { installSystemListeners() }
		startWatchdog()
		buildOutputLocked()
	}

	private func stopLocked() {
		wanted = false
		pendingRebuild?.cancel()
		pendingRebuild = nil
		watchdog?.cancel()
		watchdog = nil
		for (obj, addr, block) in systemListeners {
			var a = addr
			AudioObjectRemovePropertyListenerBlock(obj, &a, control, block)
		}
		systemListeners = []
		teardownOutputLocked()
		core.flush()
	}

	private func teardownOutputLocked() {
		core.active.store(false, ordering: .releasing)
		for (obj, addr, block) in deviceListeners {
			var a = addr
			AudioObjectRemovePropertyListenerBlock(obj, &a, control, block)
		}
		deviceListeners = []
		if let u = unit {
			AudioOutputUnitStop(u)
			AudioUnitUninitialize(u)
			AudioComponentInstanceDispose(u)
			unit = nil
		}
		// Nothing renders any more: drop stale audio so the buffered-ms stat and the next start are clean.
		core.flush(resetTrim: false)
	}

	private func buildOutputLocked() {
		teardownOutputLocked()
		guard wanted else { return }
		core.flush(resetTrim: false)
		if configuration.headless {
			core.active.store(true, ordering: .releasing)
			return
		}
		guard let device = CA.defaultOutputDevice() else {
			emit("no default output device; will retry")
			return
		}
		CA.requestBufferFrames(device, preferred: configuration.preferredIOBufferFrames)

		var desc = AudioComponentDescription(
			componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
			componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
		guard let comp = AudioComponentFindNext(nil, &desc) else { emit("HAL output component missing"); return }
		var maybeUnit: AudioUnit?
		guard AudioComponentInstanceNew(comp, &maybeUnit) == noErr, let u = maybeUnit else {
			emit("could not create output unit")
			return
		}

		func fail(_ what: String, _ status: OSStatus) {
			emit("output build failed at \(what) (\(status)); will retry")
			AudioComponentInstanceDispose(u)
		}

		// Output only: leave input disabled so no microphone permission is ever requested.
		var zero: UInt32 = 0, one: UInt32 = 1
		var st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, 4)
		if st != noErr { return fail("disable input", st) }
		st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4)
		if st != noErr { return fail("enable output", st) }
		var dev = device
		st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
		if st != noErr { return fail("set device", st) }

		// We hand the unit float stereo at the source rate; the unit converts to the device rate.
		let rate = Double(core.srcRate.load(ordering: .relaxed))
		var fmt = AudioStreamBasicDescription(
			mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
			mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
		st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
		if st != noErr { return fail("set format", st) }

		var cb = AURenderCallbackStruct(inputProc: audioPipelineRender, inputProcRefCon: Unmanaged.passUnretained(core).toOpaque())
		st = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
		if st != noErr { return fail("set callback", st) }
		st = AudioUnitInitialize(u)
		if st != noErr { return fail("initialize", st) }

		core.flush(resetTrim: false)
		core.active.store(true, ordering: .releasing)
		st = AudioOutputUnitStart(u)
		if st != noErr {
			core.active.store(false, ordering: .releasing)
			AudioUnitUninitialize(u)
			return fail("start", st)
		}
		unit = u
		deviceID = device
		lastHeartbeat = -1
		stalledTicks = 0
		let facts = CA.facts(device)
		infoLock.lock()
		deviceFacts = facts
		buildCount += 1
		let n = buildCount
		infoLock.unlock()
		installDeviceListeners(device)
		emit(String(format: "output #%d: %@ @ %.0f Hz, io buffer %d frames, est. latency %.1f ms",
		            n, facts.name, facts.sampleRate, facts.bufferFrames,
		            facts.sampleRate > 0 ? Double(facts.latencyFrames) / facts.sampleRate * 1000 : 0))
	}

	private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
	                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
	                         system: Bool, _ handler: @escaping () -> Void) {
		var addr = CA.address(selector, scope: scope)
		let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
		if AudioObjectAddPropertyListenerBlock(object, &addr, control, block) == noErr {
			if system { systemListeners.append((object, addr, block)) } else { deviceListeners.append((object, addr, block)) }
		}
	}

	private func installSystemListeners() {
		let sys = AudioObjectID(kAudioObjectSystemObject)
		addListener(sys, kAudioHardwarePropertyDefaultOutputDevice, system: true) { [weak self] in
			self?.scheduleRebuild("default output device changed", onlyIfDeviceDiffers: true)
		}
		addListener(sys, kAudioHardwarePropertyDevices, system: true) { [weak self] in
			guard let self, self.unit == nil else { return }
			self.scheduleRebuild("device list changed while no output", onlyIfDeviceDiffers: false)
		}
	}

	private func installDeviceListeners(_ device: AudioDeviceID) {
		let why: [(AudioObjectPropertySelector, AudioObjectPropertyScope, String)] = [
			(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "sample rate changed"),
			(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "device liveness changed"),
			(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, "stream configuration changed"),
			(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, "data source changed (headphones?)"),
		]
		for (sel, scope, text) in why {
			addListener(device, sel, scope: scope, system: false) { [weak self] in
				self?.scheduleRebuild(text, onlyIfDeviceDiffers: false)
			}
		}
	}

	private func scheduleRebuild(_ reason: String, onlyIfDeviceDiffers: Bool) {
		guard wanted else { return }
		if onlyIfDeviceDiffers, unit != nil, CA.defaultOutputDevice() == deviceID { return }
		emit("rebuild scheduled: \(reason)")
		pendingRebuild?.cancel()
		let item = DispatchWorkItem { [weak self] in
			guard let self, self.wanted else { return }
			self.buildOutputLocked()
		}
		pendingRebuild = item
		control.asyncAfter(deadline: .now() + 0.25, execute: item)
	}

	/// Safety net: retries a failed build, and rebuilds if the render callback stops being called.
	private func startWatchdog() {
		guard watchdog == nil, !configuration.headless else { return }
		let t = DispatchSource.makeTimerSource(queue: control)
		t.schedule(deadline: .now() + 1, repeating: 1)
		t.setEventHandler { [weak self] in
			guard let self, self.wanted else { return }
			if self.unit == nil {
				if self.pendingRebuild == nil || self.pendingRebuild!.isCancelled { self.buildOutputLocked() }
				return
			}
			let hb = self.core.heartbeat.load(ordering: .relaxed)
			if hb == self.lastHeartbeat {
				self.stalledTicks += 1
				if self.stalledTicks >= 2 {
					self.emit("render callback stalled; rebuilding output")
					self.buildOutputLocked()
				}
			} else {
				self.stalledTicks = 0
				self.lastHeartbeat = hb
			}
		}
		watchdog = t
		t.resume()
	}
}

private let audioPipelineRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
	guard let ioData else { return noErr }
	let buffer = ioData.pointee.mBuffers
	guard let data = buffer.mData else { return noErr }
	let n = min(Int(frames), Int(buffer.mDataByteSize) / 8)
	Unmanaged<AudioRenderCore>.fromOpaque(refCon)._withUnsafeGuaranteedRef {
		$0.render(data.assumingMemoryBound(to: Float.self), frames: n)
	}
	return noErr
}

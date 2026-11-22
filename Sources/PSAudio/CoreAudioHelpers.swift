import CoreAudio
import Foundation

enum CA {
	static func address(
		_ selector: AudioObjectPropertySelector,
		scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
	) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
	}

	static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
	                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
		var addr = address(selector, scope: scope)
		var value = initial
		var size = UInt32(MemoryLayout<T>.size)
		let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
		return status == noErr ? value : nil
	}

	@discardableResult
	static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
	                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> OSStatus {
		var addr = address(selector, scope: scope)
		var v = value
		return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
	}

	static func defaultOutputDevice() -> AudioDeviceID? {
		guard let id: AudioDeviceID = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)),
		      id != kAudioObjectUnknown else { return nil }
		return id
	}

	static func deviceName(_ device: AudioDeviceID) -> String {
		var addr = address(kAudioObjectPropertyName)
		var name: Unmanaged<CFString>?
		var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
		if status == noErr, let name { return name.takeRetainedValue() as String }
		return "device \(device)"
	}

	static func streamLatency(_ device: AudioDeviceID) -> UInt32 {
		var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 4 else { return 0 }
		var first = AudioObjectID(0)
		var firstSize = UInt32(MemoryLayout<AudioObjectID>.size)
		guard AudioObjectGetPropertyData(device, &addr, 0, nil, &firstSize, &first) == noErr else { return 0 }
		return get(first, kAudioStreamPropertyLatency, 0 as UInt32) ?? 0
	}

	/// Output-side device facts, gathered after the I/O buffer size has been requested.
	struct DeviceFacts {
		var name = ""
		var sampleRate = 0.0
		var bufferFrames = 0
		var latencyFrames = 0  // device + stream + safety offset + one buffer
	}

	static func facts(_ device: AudioDeviceID) -> DeviceFacts {
		var f = DeviceFacts()
		f.name = deviceName(device)
		f.sampleRate = get(device, kAudioDevicePropertyNominalSampleRate, 0.0 as Float64) ?? 0
		f.bufferFrames = Int(get(device, kAudioDevicePropertyBufferFrameSize, 0 as UInt32) ?? 0)
		let lat = get(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, 0 as UInt32) ?? 0
		let safety = get(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, 0 as UInt32) ?? 0
		f.latencyFrames = Int(lat) + Int(streamLatency(device)) + Int(safety) + f.bufferFrames
		return f
	}

	/// Ask for a small I/O buffer; the HAL clamps to what the hardware allows.
	static func requestBufferFrames(_ device: AudioDeviceID, preferred: Int) {
		guard preferred > 0 else { return }
		var wanted = UInt32(preferred)
		if let range: AudioValueRange = get(device, kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange()) {
			wanted = UInt32(max(range.mMinimum, min(range.mMaximum, Double(preferred))))
		}
		set(device, kAudioDevicePropertyBufferFrameSize, wanted)
	}
}

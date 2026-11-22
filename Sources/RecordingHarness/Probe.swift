import Foundation

enum Tool {
	static let ffprobe = "/opt/homebrew/bin/ffprobe"
	static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

	static func run(_ path: String, _ args: [String]) -> (out: Data, err: String, status: Int32) {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: path)
		p.arguments = args
		let o = Pipe(), e = Pipe()
		p.standardOutput = o
		p.standardError = e
		var outData = Data(), errData = Data()
		let g = DispatchGroup()
		g.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
		g.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
		do { try p.run() } catch { return (Data(), "\(error)", -1) }
		p.waitUntilExit()
		g.wait()
		return (outData, String(decoding: errData, as: UTF8.self), p.terminationStatus)
	}
}

struct StreamFacts {
	var codec = "", profile = "", pixFmt = "", primaries = "", transfer = "", matrix = "", range = ""
	var width = 0, height = 0, packets = 0
	var startTime = Double.nan, duration = Double.nan
	var sampleRate = 0, channels = 0, bitrate = 0
	var tag = ""
	var sideData: [String] = []
}

struct FileReport {
	var path: String
	var video = StreamFacts()
	var audio = StreamFacts()
	var formatDuration = Double.nan
	var formatStart = Double.nan
	var size: Int64 = 0
	var decodedFrames = 0
	var decodeErrors = 0
	var flashTimes: [Double] = []
	var beepTimes: [Double] = []
	var audioDecodedSeconds = Double.nan
	var ok = false
	var colr = "none"
	var hasMdcv = false, hasClli = false
}

enum Probe {
	static func analyze(_ path: String, wantSync: Bool = true) -> FileReport {
		var r = FileReport(path: path)
		r.size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
		let res = Tool.run(Tool.ffprobe, ["-v", "error", "-count_packets", "-show_streams", "-show_format", "-show_entries", "stream_side_data", "-of", "json", path])
		guard res.status == 0, let json = try? JSONSerialization.jsonObject(with: res.out) as? [String: Any] else {
			print("  ffprobe failed: \(res.err)")
			return r
		}
		func d(_ any: Any?) -> Double { Double("\(any ?? "")") ?? .nan }
		func i(_ any: Any?) -> Int { Int("\(any ?? "")") ?? 0 }
		for s in (json["streams"] as? [[String: Any]]) ?? [] {
			var f = StreamFacts()
			f.codec = s["codec_name"] as? String ?? ""
			f.profile = s["profile"] as? String ?? ""
			f.pixFmt = s["pix_fmt"] as? String ?? ""
			f.primaries = s["color_primaries"] as? String ?? ""
			f.transfer = s["color_transfer"] as? String ?? ""
			f.matrix = s["color_space"] as? String ?? ""
			f.range = s["color_range"] as? String ?? ""
			f.width = i(s["width"]); f.height = i(s["height"])
			f.packets = i(s["nb_read_packets"])
			f.startTime = d(s["start_time"]); f.duration = d(s["duration"])
			f.sampleRate = i(s["sample_rate"]); f.channels = i(s["channels"]); f.bitrate = i(s["bit_rate"])
			f.tag = s["codec_tag_string"] as? String ?? ""
			f.sideData = ((s["side_data_list"] as? [[String: Any]]) ?? []).compactMap { $0["side_data_type"] as? String }
			if s["codec_type"] as? String == "video" { r.video = f } else if s["codec_type"] as? String == "audio" { r.audio = f }
		}
		if let fmt = json["format"] as? [String: Any] { r.formatDuration = d(fmt["duration"]); r.formatStart = d(fmt["start_time"]) }
		r.ok = true
		// Colour atoms as written in the container (ffprobe also reads the bitstream VUI, so look at the bytes).
		if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
			let colr = Data("colr".utf8)
			if let range = data.range(of: colr), range.upperBound + 10 <= data.count {
				let b = [UInt8](data[range.upperBound..<(range.upperBound + 10)])
				let type = String(decoding: b[0..<4], as: UTF8.self)
				func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
				r.colr = "\(type) primaries=\(u16(4)) transfer=\(u16(6)) matrix=\(u16(8))"
			}
			r.hasMdcv = data.range(of: Data("mdcv".utf8)) != nil
			r.hasClli = data.range(of: Data("clli".utf8)) != nil
		}

		// Video: per-frame times (container) + decoded luma to find the sync flashes.
		if r.video.packets > 0 {
			let fr = Tool.run(Tool.ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time", "-of", "csv=p=0", path])
			let times = String(decoding: fr.out, as: UTF8.self).split(separator: "\n").compactMap { Double($0.split(separator: ",")[0]) }.sorted()
			let dec = Tool.run(Tool.ffmpeg, ["-v", "error", "-i", path, "-map", "0:v:0", "-vf", "scale=32:18:flags=area,format=gray", "-fps_mode", "passthrough", "-f", "rawvideo", "-"])
			let frameBytes = 32 * 18
			r.decodedFrames = dec.out.count / frameBytes
			r.decodeErrors = dec.err.split(separator: "\n").filter { !$0.contains("non monotonically") }.count
			if wantSync, r.decodedFrames == times.count {
				for k in 0..<r.decodedFrames {
					let slice = dec.out[(k * frameBytes)..<((k + 1) * frameBytes)]
					let mean = slice.reduce(0) { $0 + Int($1) } / frameBytes
					if mean > 150 { r.flashTimes.append(times[k]) }
				}
			}
		}
		// Audio: decoded PCM -> beep onsets.
		if r.audio.packets > 0 {
			let dec = Tool.run(Tool.ffmpeg, ["-v", "error", "-i", path, "-map", "0:a:0", "-f", "s16le", "-ac", "2", "-ar", "48000", "-"])
			let n = dec.out.count / 4
			r.audioDecodedSeconds = Double(n) / 48000
			if wantSync {
				dec.out.withUnsafeBytes { raw in
					let s = raw.bindMemory(to: Int16.self)
					let win = 48 // 1 ms
					var quietFor = 1000
					var w = 0
					while (w + 1) * win <= n {
						var acc = 0.0
						for j in 0..<win { let v = Double(s[2 * (w * win + j)]) / 32768; acc += v * v }
						let rms = (acc / Double(win)).squareRoot()
						if rms > 0.3 {
							if quietFor >= 100 { r.beepTimes.append(r.audio.startTime.isNaN ? 0 : r.audio.startTime + Double(w * win) / 48000) }
							quietFor = 0
						} else { quietFor += 1 }
						w += 1
					}
				}
			}
		}
		return r
	}
}

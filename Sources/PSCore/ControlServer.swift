import Darwin
import Foundation

/// The local control channel: a Unix domain socket that takes one JSON request per connection
/// and answers with one JSON response (see `ControlProtocol.swift`).
///
/// Who can reach it: only processes of the same user. The socket file is created with mode
/// 0600 inside a 0700 directory, and every connection's peer user id is checked as well.
///
/// What it costs the stream: nothing while idle (one thread blocked in `poll`). Requests are
/// read, handled and answered on utility-priority threads; the server never touches the main
/// thread or a stream thread itself. What a command does is up to the handler.
public final class ControlServer: @unchecked Sendable {
	public typealias Handler = (ControlRequest) async -> ControlResponse

	public enum ServerError: Error, LocalizedError {
		case pathTooLong(String)
		case system(String, Int32)

		public var errorDescription: String? {
			switch self {
			case .pathTooLong(let path): return "Control socket path is too long for a Unix socket: \(path)"
			case .system(let what, let code): return "Control socket: \(what) failed: \(String(cString: strerror(code)))"
			}
		}
	}

	public let socketURL: URL
	private let handler: Handler
	private let lock = NSLock()
	private var listenFD: Int32 = -1
	/// Inode of the socket file we created, so `stop` never removes a newer instance's socket.
	private var boundInode: UInt64 = 0
	private var wakePipe: (read: Int32, write: Int32) = (-1, -1)
	private var acceptThread: Thread?
	private let workers = DispatchQueue(label: "playstream.control.connection", qos: .utility, attributes: .concurrent)
	private var activeConnections = 0

	/// Largest request accepted, bytes.
	public static let maxRequestBytes = 1 << 20
	/// Most connections served at once; further ones are refused with an error line.
	public static let maxConnections = 16
	/// How long a client may take to send its request line.
	public static let readTimeoutSeconds = 5
	/// `start` makes the process ignore SIGPIPE (see there). Only tests turn this off, to prove
	/// the socket-level protection on its own.
	nonisolated(unsafe) public static var ignoresSIGPIPE = true

	public static var defaultSocketURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base.appendingPathComponent("PlayStream/control.sock")
	}

	public init(socketURL: URL = ControlServer.defaultSocketURL, handler: @escaping Handler) {
		self.socketURL = socketURL
		self.handler = handler
	}

	deinit { stop() }

	public var isRunning: Bool {
		lock.lock()
		defer { lock.unlock() }
		return listenFD >= 0
	}

	/// Creates the socket and starts accepting. A socket file left behind by an earlier
	/// instance (or still held by one that is on its way out) is replaced: the newest instance
	/// owns the channel.
	public func start() throws {
		lock.lock()
		defer { lock.unlock() }
		guard listenFD < 0 else { return }

		let path = socketURL.path
		var address = sockaddr_un()
		let capacity = MemoryLayout.size(ofValue: address.sun_path)
		guard path.utf8.count < capacity else { throw ServerError.pathTooLong(path) }

		let directory = socketURL.deletingLastPathComponent()
		if !FileManager.default.fileExists(atPath: directory.path) {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		}

		// A client that hangs up before its answer is written must never kill the host. Two
		// layers: the listening socket carries SO_NOSIGPIPE, which accepted sockets inherit
		// (setting it on an accepted socket fails once the peer is gone, which is exactly the
		// case that matters), and SIGPIPE is ignored process-wide, the usual choice for a
		// program that talks to sockets.
		if ControlServer.ignoresSIGPIPE { signal(SIGPIPE, SIG_IGN) }

		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw ServerError.system("socket", errno) }
		_ = fcntl(fd, F_SETFD, FD_CLOEXEC)
		var noSigPipe: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

		address.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &address.sun_path) { raw in
			raw.copyBytes(from: path.utf8)
		}
		unlink(path)
		// Create the file with 0600 from the start (no window in which it is wider).
		let previousMask = umask(0o177)
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		let bindError = errno
		umask(previousMask)
		guard bound == 0 else {
			close(fd)
			throw ServerError.system("bind", bindError)
		}
		chmod(path, 0o600)
		guard listen(fd, 64) == 0 else {
			let code = errno
			close(fd)
			unlink(path)
			throw ServerError.system("listen", code)
		}
		var info = stat()
		boundInode = stat(path, &info) == 0 ? UInt64(info.st_ino) : 0

		var fds: [Int32] = [-1, -1]
		guard pipe(&fds) == 0 else {
			let code = errno
			close(fd)
			unlink(path)
			throw ServerError.system("pipe", code)
		}
		_ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
		_ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
		wakePipe = (fds[0], fds[1])
		listenFD = fd

		let wakeFD = fds[0]
		// The thread must not keep the server alive: it only looks it up per connection.
		let thread = Thread { [weak self] in ControlServer.acceptLoop(listenFD: fd, wakeFD: wakeFD, server: { self }) }
		thread.name = "playstream.control.accept"
		thread.qualityOfService = .utility
		acceptThread = thread
		thread.start()
	}

	/// Stops accepting and removes the socket file. Requests already being handled finish.
	public func stop() {
		lock.lock()
		let fd = listenFD
		let pipeFDs = wakePipe
		let inode = boundInode
		listenFD = -1
		wakePipe = (-1, -1)
		boundInode = 0
		acceptThread = nil
		lock.unlock()
		guard fd >= 0 else { return }

		var info = stat()
		if stat(socketURL.path, &info) == 0, UInt64(info.st_ino) == inode {
			unlink(socketURL.path)
		}
		// Wake the accept thread; it closes the listening socket and its end of the pipe.
		var byte: UInt8 = 1
		_ = write(pipeFDs.write, &byte, 1)
		close(pipeFDs.write)
	}

	// MARK: Accepting

	private static func acceptLoop(listenFD: Int32, wakeFD: Int32, server: () -> ControlServer?) {
		defer {
			close(listenFD)
			close(wakeFD)
		}
		while true {
			var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)]
			let ready = poll(&fds, 2, -1)
			if ready < 0 {
				if errno == EINTR { continue }
				return
			}
			if fds[1].revents != 0 { return }
			guard fds[0].revents & Int16(POLLIN) != 0 else {
				if fds[0].revents != 0 { return }
				continue
			}
			let client = accept(listenFD, nil, nil)
			if client < 0 {
				if errno == EINTR || errno == ECONNABORTED { continue }
				return
			}
			guard let current = server() else {
				close(client)
				return
			}
			current.serve(client)
		}
	}

	private func serve(_ client: Int32) {
		_ = fcntl(client, F_SETFD, FD_CLOEXEC)
		// Inherited from the listening socket; set again in case that ever changes. This call
		// fails when the client has already gone, which is why it cannot be the only protection.
		var on: Int32 = 1
		setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		var timeout = timeval(tv_sec: ControlServer.readTimeoutSeconds, tv_usec: 0)
		setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var sendTimeout = timeval(tv_sec: 10, tv_usec: 0)
		setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

		lock.lock()
		let admitted = activeConnections < ControlServer.maxConnections
		if admitted { activeConnections += 1 }
		lock.unlock()
		guard admitted else {
			ControlServer.send(ControlResponse.failure("too many control connections").encoded(), to: client)
			close(client)
			return
		}

		workers.async { [self] in
			let finish: @Sendable () -> Void = { [self] in
				close(client)
				lock.lock()
				activeConnections -= 1
				lock.unlock()
			}

			var uid: uid_t = 0
			var gid: gid_t = 0
			guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
				ControlServer.send(ControlResponse.failure("permission denied").encoded(), to: client)
				finish()
				return
			}

			let request: ControlRequest
			do {
				request = try ControlRequest.parse(try ControlServer.readLine(from: client))
			} catch {
				ControlServer.send(ControlResponse.failure("\(error)").encoded(), to: client)
				finish()
				return
			}
			let handler = self.handler
			Task.detached(priority: .utility) {
				let encoded = await handler(request).encoded()
				// Blocking socket I/O belongs on a plain thread, not on the cooperative pool.
				self.workers.async {
					ControlServer.send(encoded, to: client)
					finish()
				}
			}
		}
	}

	// MARK: Socket I/O

	private static func readLine(from fd: Int32) throws -> Data {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 16 * 1024)
		while true {
			let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
			if n < 0 {
				if errno == EINTR { continue }
				throw ControlError(errno == EAGAIN || errno == EWOULDBLOCK ? "timed out waiting for the request" : "read failed: \(String(cString: strerror(errno)))")
			}
			if n == 0 { break }
			data.append(contentsOf: buffer[0..<n])
			if let newline = data.firstIndex(of: 0x0A) {
				data = data[data.startIndex..<newline]
				break
			}
			if data.count > maxRequestBytes { throw ControlError("request is too large") }
		}
		return data
	}

	private static func send(_ data: Data, to fd: Int32) {
		data.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
				if n < 0 {
					if errno == EINTR { continue }
					return
				}
				if n == 0 { return }
				offset += n
			}
		}
	}
}

// MARK: - Client

/// Minimal client for the control channel (used by the test host; `scripts/psctl` is the
/// command-line client).
public enum ControlClient {
	public static func send(_ request: ControlRequest, to socketURL: URL, timeout: TimeInterval = 30) throws -> [String: Any] {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw ControlError("socket failed") }
		defer { close(fd) }
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let path = socketURL.path
		guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError("socket path too long") }
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		guard connected == 0 else { throw ControlError("cannot connect to \(path): \(String(cString: strerror(errno)))") }

		guard var body = JSONValue.encode(JSONValue.sanitized(["cmd": request.command, "args": request.args, "opts": request.options] as [String: Any])) else { throw ControlError("request cannot be encoded") }
		body.append(0x0A)
		let sent = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
		guard sent == body.count else { throw ControlError("could not send the request") }

		var response = Data()
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		while true {
			let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
			if n < 0 {
				if errno == EINTR { continue }
				throw ControlError("no response: \(String(cString: strerror(errno)))")
			}
			if n == 0 { break }
			response.append(contentsOf: buffer[0..<n])
		}
		guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
			throw ControlError("response is not a JSON object")
		}
		return object
	}
}

import Foundation
import Network

private final class ConnectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor public protocol MCFConnection: AnyObject {
    func connect() async throws
    func cancel()
    func send(_ packet: MCFPacket) async throws
    func receive() async throws -> MCFPacket
}

public final class MCFTransport: MCFConnection {
    private var socket: NWConnection
    private var buffer = Data()
    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        socket = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
    }
    init(socket: NWConnection) { self.socket = socket }
    public func cancel() { socket.cancel() }
    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ConnectionCompletion(continuation)
            socket.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(ContinuityError.message("Connection cancelled or timed out.")))
                default: break
                }
            }
            socket.start(queue: DispatchQueue(label: "GalaxyContinuityLab.connection"))
        }
    }
    public func send(_ packet: MCFPacket) async throws {
        try await sendFrame(packet.encoded)
    }
    func sendFrame(_ frame: Data) async throws {
        guard frame.count <= ProtoWire.maximumFrame else { throw ContinuityError.message("Outgoing frame is too large.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(content: ProtoWire.varint(UInt64(frame.count)) + frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    /// Raw pre-framed socket write for synchronous sends off the main actor
    /// (the pointer worker). Captured on the main actor; NWConnection itself
    /// is thread-safe, so the closure can run from any thread.
    var blockingWriter: (Data, @escaping (Error?) -> Void) -> Void {
        { [socket] content, completion in
            socket.send(content: content, completion: .contentProcessed { error in completion(error) })
        }
    }
    private func more() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ContinuityError.message(complete ? "The peer closed the connection." : "No data from peer.")) }
            }
        }
        guard buffer.count + data.count <= ProtoWire.maximumFrame + 65546 else { throw ContinuityError.message("Incoming frame exceeds the transport limit.") }
        buffer += data
    }
    public func receive() async throws -> MCFPacket {
        try MCFPacket(data: await receiveFrame())
    }
    func receiveFrame() async throws -> Data {
        var length: Int?, prefix = 0
        while length == nil {
            var cursor = 0
            if let value = try? ProtoWire.readVarint(buffer, cursor: &cursor) {
                guard value <= ProtoWire.maximumFrame else { throw ContinuityError.message("Peer frame is too large.") }
                length = Int(value); prefix = cursor
            } else {
                guard buffer.count < 10 else { throw ContinuityError.message("Invalid transport length prefix.") }
                try await more()
            }
        }
        while buffer.count < prefix + length! { try await more() }
        let begin = buffer.startIndex + prefix
        let body = buffer.subdata(in: begin..<(begin + length!)); buffer = Data(buffer.dropFirst(prefix + length!))
        return body
    }
}

public extension MCFConnection {
    func authenticate(profile: ContinuityProfile, channel: String? = nil) async throws -> MCFHandshake {
        let deadline = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { self.cancel() } }
        defer { deadline.cancel() }
        try await connect()
        let handshake = try MCFHandshake(profile: profile)
        try await send(handshake.initiate(channel: channel))
        let reply = try await receive()
        try await send(handshake.finish(reply))
        return handshake
    }
}

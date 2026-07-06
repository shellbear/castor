import Foundation
import Network

/// A CASTv2 socket: TLS to port 8009, length-prefixed protobuf frames,
/// heartbeat, and requestId-correlated request/response on top.
actor CastChannel {
    enum ChannelError: Error {
        case notConnected
        case remoteClosed
        case timeout
    }

    struct Envelope: Sendable {
        let namespace: String
        let sourceId: String
        let payload: Data
    }

    private let endpoint: NWEndpoint
    private let senderId = "sender-0"
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var nextRequestId = 100
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var listeners: [UUID: AsyncStream<Envelope>.Continuation] = [:]

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: - Lifecycle

    func connect() async throws {
        guard connection == nil else { return }

        let tls = NWProtocolTLS.Options()
        // Cast devices present self-signed certificates; the protocol relies
        // on being on the same LAN rather than on PKI.
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            .global()
        )
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: tls))
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let resumed = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.trySet() { cont.resume() }
                case .failed(let error):
                    if resumed.trySet() { cont.resume(throwing: error) }
                case .cancelled:
                    if resumed.trySet() { cont.resume(throwing: ChannelError.notConnected) }
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "castor.cast.channel"))
        }
        conn.stateUpdateHandler = nil

        try await send(
            namespace: CastNamespace.connection,
            destination: "receiver-0",
            payload: SimplePayload(type: "CONNECT")
        )
        startReceiveLoop(on: conn)
        startHeartbeat()
    }

    func close() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        connection?.cancel()
        connection = nil
        for cont in pending.values {
            cont.resume(throwing: ChannelError.notConnected)
        }
        pending.removeAll()
        for listener in listeners.values {
            listener.finish()
        }
        listeners.removeAll()
    }

    // MARK: - Messaging

    func send(namespace: String, destination: String, payload: some Encodable) async throws {
        guard let connection else { throw ChannelError.notConnected }
        let json = try JSONEncoder().encode(payload)
        let message = CastMessage(
            sourceId: senderId,
            destinationId: destination,
            namespace: namespace,
            payload: String(decoding: json, as: UTF8.self)
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: message.encodedFrame(), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func request<Response: Decodable>(
        namespace: String,
        destination: String,
        payload: some RequestPayload,
        as type: Response.Type,
        timeout: Duration = .seconds(10)
    ) async throws -> Response {
        nextRequestId += 1
        let id = nextRequestId
        var payload = payload
        payload.requestId = id

        let data: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do {
                    try await self.send(namespace: namespace, destination: destination, payload: payload)
                } catch {
                    await self.finishRequest(id, with: .failure(error))
                    return
                }
                try? await Task.sleep(for: timeout)
                await self.finishRequest(id, with: .failure(ChannelError.timeout))
            }
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// All non-heartbeat traffic, including unsolicited status pushes.
    func subscribe() -> AsyncStream<Envelope> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    // MARK: - Internals

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func finishRequest(_ id: Int, with result: Result<Data, any Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: result)
    }

    private func startReceiveLoop(on conn: NWConnection) {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let header = try await Self.receiveExactly(4, on: conn)
                    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
                    guard length > 0, length < 1 << 20 else { continue }
                    let body = try await Self.receiveExactly(Int(length), on: conn)
                    handle(try CastMessage.decode(body: body))
                } catch {
                    close()
                    return
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                do {
                    try await send(
                        namespace: CastNamespace.heartbeat,
                        destination: "receiver-0",
                        payload: SimplePayload(type: "PING")
                    )
                } catch {
                    close()
                    return
                }
            }
        }
    }

    private func handle(_ message: CastMessage) {
        let data = Data(message.payload.utf8)
        let header = try? JSONDecoder().decode(IncomingHeader.self, from: data)

        if message.namespace == CastNamespace.heartbeat {
            if header?.type == "PING" {
                Task {
                    try? await send(
                        namespace: CastNamespace.heartbeat,
                        destination: message.sourceId,
                        payload: SimplePayload(type: "PONG")
                    )
                }
            }
            return
        }

        if let requestId = header?.requestId, requestId != 0 {
            finishRequest(requestId, with: .success(data))
        }
        let envelope = Envelope(namespace: message.namespace, sourceId: message.sourceId, payload: data)
        for listener in listeners.values {
            listener.yield(envelope)
        }
    }

    private static func receiveExactly(_ count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(throwing: ChannelError.remoteClosed)
                }
            }
        }
    }
}

/// Thread-safe run-once guard for callback-based APIs that may fire twice.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}

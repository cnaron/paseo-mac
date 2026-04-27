import Foundation

/// E2EE channel over a relay WebSocket. Mirrors `createClientChannel()` in
/// `packages/relay/src/encrypted-channel.ts`.
///
/// Lifecycle:
/// 1. `start()` connects to `wss://relay/ws?serverId=...&role=client&v=2`
/// 2. Sends `{"type":"e2ee_hello","key":<ourPubKeyB64>}`
/// 3. Waits for `{"type":"e2ee_ready"}` from the daemon side
/// 4. All subsequent frames are base64-encoded ciphertext bundles
///
/// The channel exposes:
/// - `send(_ data:)` to encrypt + send one application frame
/// - `incoming` as an AsyncStream of decrypted frames (UTF-8 bytes)
actor RelayChannel {

    enum State: Equatable {
        case idle
        case connecting
        case handshaking
        case open
        case closed(reason: String?)
    }

    // MARK: - Config

    let relayURL: URL
    private let daemonPublicKey: Data
    private let session: URLSession
    /// How long we'll wait for the daemon's `e2ee_ready` before giving up.
    /// Without this, the hello retry loop would spin forever when the
    /// daemon isn't registered on the relay.
    private let handshakeTimeout: TimeInterval

    // MARK: - State

    private var state: State = .idle
    private var task: URLSessionWebSocketTask?
    private var sharedKey: Data?
    private var ourPublicKeyB64: String?
    private var helloRetryTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?
    private var pendingBeforeOpen: [Data] = []
    private var openContinuation: CheckedContinuation<Void, Error>?

    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    // MARK: - Init

    init(
        relayURL: URL,
        daemonPublicKeyB64: String,
        session: URLSession = .shared,
        handshakeTimeout: TimeInterval = 15
    ) throws {
        self.relayURL = relayURL
        guard let pubKey = Data(base64Encoded: daemonPublicKeyB64) else {
            throw RelayChannelError.invalidDaemonPublicKey
        }
        self.daemonPublicKey = pubKey
        self.session = session
        self.handshakeTimeout = handshakeTimeout
        var cont: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { cont = $0 }
        self.incomingContinuation = cont
    }

    // MARK: - Public API

    /// Opens the WebSocket, performs the E2EE handshake, and resolves when the channel is ready.
    /// Throws on handshake / connection failure.
    func start() async throws {
        guard state == .idle else { throw RelayChannelError.alreadyStarted }
        state = .connecting

        let ourKeyPair = try RelayCrypto.generateKeyPair()
        self.sharedKey = try RelayCrypto.deriveSharedKey(
            ourSecretKey: ourKeyPair.secretKey,
            peerPublicKey: daemonPublicKey
        )
        self.ourPublicKeyB64 = ourKeyPair.publicKey.base64EncodedString()

        let task = session.webSocketTask(with: relayURL)
        self.task = task
        task.resume()

        state = .handshaking

        // Start the receive loop before we send `e2ee_hello` so we don't miss `e2ee_ready`.
        self.receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop()
        }

        // Fire off `e2ee_hello` and retry every 1s until we see `e2ee_ready`.
        self.helloRetryTask = Task { [weak self] in
            await self?.runHelloRetry()
        }

        // Fail the handshake if the daemon never sends `e2ee_ready` in time.
        // This is the common failure mode when the daemon isn't registered
        // with the relay (e.g. VPS daemon crashed or lost its control socket).
        let timeout = handshakeTimeout
        self.handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.failHandshakeIfStillPending()
        }

        // Block until the handshake completes or fails.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.openContinuation = cont
        }
    }

    /// Encrypts `data` and sends it. Buffers if the channel is still handshaking.
    func send(_ data: Data) async throws {
        switch state {
        case .idle, .connecting:
            throw RelayChannelError.notConnected
        case .handshaking:
            pendingBeforeOpen.append(data)
        case .open:
            try await encryptAndSend(data)
        case .closed(let reason):
            throw RelayChannelError.channelClosed(reason ?? "closed")
        }
    }

    /// Sends a WebSocket-level PING to the relay server to keep the connection alive.
    /// Returns `true` if the ping succeeded, `false` if the connection is dead.
    func sendKeepalivePing() async -> Bool {
        guard state == .open, let task else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            task.sendPing { error in cont.resume(returning: error == nil) }
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: String = "bye") {
        guard state != .closed(reason: reason) else { return }
        helloRetryTask?.cancel()
        helloRetryTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: code, reason: reason.data(using: .utf8))
        task = nil
        state = .closed(reason: reason)
        failOpenContinuation(with: RelayChannelError.channelClosed(reason))
        incomingContinuation.finish()
    }

    // MARK: - Internals

    private func encryptAndSend(_ data: Data) async throws {
        guard let sharedKey else { throw RelayChannelError.notConnected }
        guard let task else { throw RelayChannelError.notConnected }
        let bundle = try RelayCrypto.encrypt(sharedKey: sharedKey, plaintext: data)
        let base64 = bundle.base64EncodedString()
        try await task.send(.string(base64))
    }

    private func runHelloRetry() async {
        guard let pubKeyB64 = ourPublicKeyB64 else { return }
        let hello = #"{"type":"e2ee_hello","key":"\#(pubKeyB64)"}"#
        while !Task.isCancelled, state == .handshaking {
            do {
                try await task?.send(.string(hello))
            } catch {
                debug("e2ee_hello send failed: \(error)")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func failHandshakeIfStillPending() {
        guard state == .handshaking else { return }
        debug("handshake timed out after \(handshakeTimeout)s")
        helloRetryTask?.cancel()
        helloRetryTask = nil
        task?.cancel(with: .goingAway, reason: Data("handshake timeout".utf8))
        task = nil
        state = .closed(reason: "handshake timeout")
        failOpenContinuation(with: RelayChannelError.handshakeTimedOut)
        incomingContinuation.finish()
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            guard let task else { return }
            do {
                let msg = try await task.receive()
                await handleMessage(msg)
            } catch {
                await handleReceiveError(error)
                return
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) async {
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }

        switch state {
        case .handshaking:
            // Expect `{"type":"e2ee_ready"}`. Any other JSON control frame is ignored.
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               obj["type"] as? String == "e2ee_ready" {
                state = .open
                helloRetryTask?.cancel()
                helloRetryTask = nil
                handshakeTimeoutTask?.cancel()
                handshakeTimeoutTask = nil
                resumeOpenContinuation()
                await flushPendingAfterOpen()
            }
        case .open:
            // Ignore stray plaintext handshake frames (daemon may resend `e2ee_ready`).
            if text.hasPrefix("{") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    if let t = obj["type"] as? String, t == "e2ee_ready" || t == "e2ee_hello" {
                        return
                    }
                }
            }
            // Otherwise it must be base64 ciphertext.
            guard let bundle = Data(base64Encoded: text),
                  let sharedKey else {
                debug("dropping malformed frame (len=\(text.count))")
                return
            }
            do {
                let plaintext = try RelayCrypto.decrypt(sharedKey: sharedKey, bundle: bundle)
                incomingContinuation.yield(plaintext)
            } catch {
                debug("decrypt failed: \(error); closing channel")
                close(code: .internalServerError, reason: "decrypt")
            }
        default:
            return
        }
    }

    private func handleReceiveError(_ error: Error) async {
        debug("receive error: \(error)")
        let reason = (error as? URLError)?.localizedDescription ?? String(describing: error)
        failOpenContinuation(with: RelayChannelError.channelClosed(reason))
        state = .closed(reason: reason)
        helloRetryTask?.cancel()
        helloRetryTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        incomingContinuation.finish()
    }

    private func flushPendingAfterOpen() async {
        let pending = pendingBeforeOpen
        pendingBeforeOpen.removeAll()
        for data in pending {
            do {
                try await encryptAndSend(data)
            } catch {
                debug("flush failed: \(error)")
            }
        }
    }

    private func resumeOpenContinuation() {
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume()
        }
    }

    private func failOpenContinuation(with error: Error) {
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume(throwing: error)
        }
    }

    private func debug(_ msg: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" {
            fputs("[relay] \(msg())\n", stderr)
        }
    }
}

enum RelayChannelError: Error, LocalizedError {
    case invalidDaemonPublicKey
    case alreadyStarted
    case notConnected
    case handshakeTimedOut
    case channelClosed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDaemonPublicKey:
            return "The offer link is malformed (daemon public key isn't valid base64). Regenerate the offer and try again."
        case .alreadyStarted:
            return "Relay channel already started."
        case .notConnected:
            return "Relay channel is not connected."
        case .handshakeTimedOut:
            return "Couldn't reach the daemon through the relay (handshake timed out). Check that the daemon is running on the VPS and that its offer link is current — if the daemon was restarted or reinstalled, you may need a fresh offer."
        case .channelClosed(let reason):
            return Self.friendlyClosedMessage(reason: reason)
        }
    }

    /// Humanize the raw reason string we get from `URLError` / WS close frames.
    private static func friendlyClosedMessage(reason: String) -> String {
        let lower = reason.lowercased()
        // Relay explicitly closed us because the daemon side went away.
        if lower.contains("client disconnected")
            || lower.contains("going away")
            || lower.contains("1001")
            || lower.contains("1006") {
            return "The relay dropped the connection — usually this means the daemon restarted or lost its link to the relay. Try reconnecting; if it keeps failing, restart the daemon (`paseo daemon restart` on the VPS)."
        }
        if lower.contains("cannot connect") || lower.contains("could not connect") || lower.contains("offline") {
            return "Can't reach the relay server. Check your network connection and that the relay hostname in the offer is correct."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Relay connection timed out. Network may be flaky, or the relay is unreachable."
        }
        if lower.contains("decrypt") {
            return "Decryption failed — the offer's daemon key doesn't match the running daemon. Regenerate the offer link on the VPS."
        }
        return "Relay connection closed: \(reason)"
    }
}

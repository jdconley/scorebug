#if DEBUG
import Foundation
import Network

/// Owned by the Debug app for a single explicit physical test run. All mutable
/// listener/connection state is confined to queue. Release has no implementation.
final class RecoveryLoopbackBridge {
    private let configuration: RecoveryLoopbackConfiguration
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scorebug.debug.recovery-loopback")
    private let lifetime: TimeInterval
    private let upstreamConfiguration: URLSessionConfiguration
    private var clients: [UUID: NWConnection] = [:]
    private var upstream: [UUID: RecoveryBridgeUpstream] = [:]
    private var mutation: UUID?
    private var started = false
    private var stopping = false
    private var listenerStopped = false
    private var stopClient: UUID?
    private var ready: ((Bool) -> Void)?

    init(configuration: RecoveryLoopbackConfiguration, lifetime: TimeInterval = 900,
         upstreamConfiguration: URLSessionConfiguration = .ephemeral) throws {
        guard lifetime > 0, lifetime <= 900 else { throw RecoveryLoopbackConfiguration.Failure.invalid }
        self.configuration = configuration; self.lifetime = lifetime
        self.upstreamConfiguration = upstreamConfiguration.copy() as! URLSessionConfiguration
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuration.port)!)
        listener = try NWListener(using: parameters)
    }
    func start(_ ready: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            guard !self.started, !self.stopping else { ready(false); return }
            self.started = true; self.ready = ready
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.ready?(true); self.ready = nil
                case .failed, .waiting: self.ready?(false); self.ready = nil; self.beginStop()
                case .cancelled: self.listenerStopped = true; self.finishStop()
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.lifetime) { [weak self] in self?.beginStop() }
        }
    }
    func stop() { queue.async { self.beginStop() } }

    private func accept(_ connection: NWConnection) {
        guard !stopping, clients.count < 4 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled:
                connection.stateUpdateHandler = nil
                self.clients.removeValue(forKey: id)
                self.upstream[id]?.cancel()
                self.finishStop()
            case .failed: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.clients[id]?.cancel() }
        receive(id, data: Data())
    }
    private func receive(_ id: UUID, data: Data) {
        guard let connection = clients[id], !stopping else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            guard let self, self.clients[id] != nil, !self.stopping else { return }
            var bytes = data; if let chunk { bytes.append(chunk) }
            do {
                if let request = try RecoveryLoopbackRequest.parse(bytes, configuration: self.configuration) {
                    self.handle(request, id: id)
                } else if error != nil || complete { connection.cancel() }
                else { self.receive(id, data: bytes) }
            } catch { self.respond(id, status: 400, body: Data("{\"error\":\"Invalid request\"}".utf8)) }
        }
    }
    private func handle(_ request: RecoveryLoopbackRequest, id: UUID) {
        if request.path == "/stop" { beginStop(replyTo: id); return }
        if request.method == "POST" {
            guard mutation == nil else { respond(id, status: 409, body: Data()); return }
            mutation = id
        }
        let url = request.path == "/api-health" ? configuration.api :
            (request.path == "/" ? configuration.controller : configuration.controller.appendingPathComponent(String(request.path.dropFirst())))
        var forwarded = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        forwarded.httpMethod = request.method
        forwarded.setValue("close", forHTTPHeaderField: "Connection")
        if request.path != "/api-health" { forwarded.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization") }
        if request.method == "POST" {
            forwarded.setValue("application/json", forHTTPHeaderField: "Content-Type")
            forwarded.httpBody = request.body
        }
        let operation = RecoveryBridgeUpstream(request: forwarded, configuration: upstreamConfiguration) { [weak self] status, body, forwarded in
            guard let self else { return }
            self.queue.async {
                self.upstream.removeValue(forKey: id)
                if self.mutation == id { self.mutation = nil }
                if !self.stopping { self.respond(id, status: status, body: body, forwarded: forwarded) }
                self.finishStop()
            }
        }
        upstream[id] = operation
        operation.start()
    }
    private func respond(_ id: UUID, status: Int, body: Data, forwarded: Bool = false) {
        guard let connection = clients[id] else { return }
        var wire = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nX-Scorebug-Loopback-Upstream: \(forwarded ? "1" : "0")\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        wire.append(body)
        connection.send(content: wire, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func beginStop(replyTo id: UUID? = nil) {
        guard !stopping else { return }
        stopping = true; stopClient = id
        ready?(false); ready = nil
        listener.cancel()
        for (clientID, connection) in clients where clientID != id { connection.cancel() }
        for operation in upstream.values { operation.cancel() }
        finishStop()
    }
    private func finishStop() {
        guard stopping, listenerStopped, upstream.isEmpty,
              clients.keys.allSatisfy({ $0 == stopClient }), let id = stopClient else { return }
        stopClient = nil
        respond(id, status: 200, body: Data("{\"stopped\":true}".utf8))
    }
}

/// One session and one task per exchange; streaming size enforcement avoids
/// buffering an unbounded LAN response. Redirects and automatic auth are denied.
private final class RecoveryBridgeUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let completion: (Int, Data, Bool) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private var data = Data()
    private var status: Int?
    private var rejected = false
    init(request: URLRequest, configuration: URLSessionConfiguration, completion: @escaping (Int, Data, Bool) -> Void) {
        self.request = request; self.completion = completion
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 3
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        task = session.dataTask(with: request)
    }
    func start() { task.resume() }
    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 4096,
              !(300...399).contains(http.statusCode) else {
            rejected = true; completionHandler(.cancel); return
        }
        status = http.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !rejected, data.count + chunk.count <= 4096 else { rejected = true; task.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        rejected = true; completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if error == nil, !rejected, let status { completion(status, data, true) }
        else { completion(502, Data("{\"error\":\"Upstream failed\"}".utf8), false) }
    }
}
#endif

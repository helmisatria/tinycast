import Foundation
import Network

@MainActor
final class MCPOAuthListener {
    nonisolated static let redirectURI = "http://127.0.0.1:4962/callback"
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var task: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var reply: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var accepted = false

    isolated deinit {
        listener?.cancel()
        task?.cancel()
        for reader in readers.values { reader.cancel() }
        for connection in connections.values { connection.cancel() }
    }

    func start(
        state: String, issuer: String, requiresIssuer: Bool, timeout: Duration = .seconds(300)
    ) async throws {
        guard result == nil else { throw CancellationError() }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 4962)
        let listener = try NWListener(using: parameters)
        listener.newConnectionLimit = 16
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor [weak self] in
                switch status {
                case .ready:
                    self?.ready?.resume()
                    self?.ready = nil
                case .waiting, .failed:
                    self?.finish(.failure(MCPOAuth.Failure.listenerUnavailable))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.result == nil else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.readers[id] = Task { [weak self] in
                    await self?.receive(
                        connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                    self?.connections.removeValue(forKey: id)
                    self?.readers.removeValue(forKey: id)
                    connection.cancel()
                }
            }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                task = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.finish(.failure(MCPOAuth.Failure.timedOut))
                    } catch { return }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        ready?.resume(throwing: result.failure ?? CancellationError())
        ready = nil
        reply?.resume(with: result)
        reply = nil
        listener?.cancel()
        listener = nil
        for reader in readers.values { reader.cancel() }
        for connection in connections.values { connection.cancel() }
        readers.removeAll()
        connections.removeAll()
        task?.cancel()
        task = nil
    }

    private func read(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let received: (content: Data, complete: Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: 1, maximumLength: 8192 - bytes.count
                ) { content, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (content ?? Data(), complete))
                    }
                }
            }
            bytes.append(received.content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if received.complete { return }
        }
        guard !accepted else { return }
        guard let request = String(bytes: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
            return
        }
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        var outcome: Result<String, Error>?
        if parts.count == 3, parts[0] == "GET" {
            do {
                let code = try MCPOAuth.callback(
                    String(parts[1]), state: state, issuer: issuer,
                    requiresIssuer: requiresIssuer)
                outcome = .success(code)
            } catch MCPOAuth.Failure.denied {
                outcome = .failure(MCPOAuth.Failure.denied)
            } catch { outcome = nil }
        }
        let status = outcome == nil ? "400 Bad Request" : "200 OK"
        let page =
            outcome == nil ? "Invalid sign-in response." : "Return to Tinycast. You can close this tab."
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
        if outcome != nil { self.accepted = true }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: Data(response.utf8), isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
            }
        } catch {
            if let outcome { self.finish(outcome) }
            throw error
        }
        if let outcome { self.finish(outcome) }
    }

    private func receive(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) async {
        await withTaskCancellationHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        try await self?.read(
                            connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        connection.cancel()
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch { return }
        } onCancel: {
            connection.cancel()
        }
    }
}

private extension Result where Success == String, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

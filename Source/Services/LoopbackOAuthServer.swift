//
//  LoopbackOAuthServer.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import Network

/// A one-shot loopback HTTP listener used to capture an OAuth redirect for
/// providers that reject custom URL schemes and require an http(s) redirect
/// URI (Notion, Google desktop clients). It binds 127.0.0.1 on a fixed port,
/// waits for the single redirect request, parses its query, replies with a
/// "you can close this window" page, and stops.
///
/// All mutable state is confined to a private serial queue, so the type is a
/// safe `@unchecked Sendable` despite the Network framework's escaping handlers.
final class LoopbackOAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.strategicnerds.SyncNerds.oauth-loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    /// Resolves with the query items of the first GET request received on
    /// `127.0.0.1:port`, then tears the listener down.
    func waitForCallback(port: UInt16) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.startListener(port: port)
            }
        }
    }

    private func startListener(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(.failure(OAuthError.cannotStartSession))
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(.failure(error)) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                let items = Self.parseQuery(fromRequestLine: request)
                let body = "<!doctype html><html><body style=\"font-family:-apple-system,Helvetica,sans-serif;text-align:center;padding:48px;\"><h2>SyncNerds is connected.</h2><p>You can close this window and return to the app.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self.finish(.success(items))
            } else if let error {
                self.finish(.failure(error))
            }
        }
    }

    /// Must be called on `queue`. Resolves the continuation exactly once and
    /// shuts the listener down.
    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let items): continuation?.resume(returning: items)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    /// Parses the query items out of an HTTP request's start line, e.g.
    /// `GET /oauth/notion?code=abc&state=xyz HTTP/1.1`.
    static func parseQuery(fromRequestLine request: String) -> [String: String] {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? request
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2 else { return [:] }
        let target = String(fields[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else { return [:] }
        var out: [String: String] = [:]
        for item in components.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }
}

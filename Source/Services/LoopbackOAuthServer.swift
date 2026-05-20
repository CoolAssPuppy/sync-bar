//
//  LoopbackOAuthServer.swift
//  SyncBar
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
    private let queue = DispatchQueue(label: "com.strategicnerds.SyncBar.oauth-loopback")
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
                let body = Self.successPageHTML
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

    // SVG path data in the embedded HTML can't be line-wrapped.
    // swiftlint:disable line_length
    /// Branded "connected" page shown in the browser after the OAuth redirect.
    /// Strategic Nerds charcoal + yellow; attempts to auto-close the tab and
    /// falls back to the close-this-window instruction when the browser blocks it.
    private static let successPageHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Sync Bar</title>
      <style>
        :root { color-scheme: dark; }
        html, body { height: 100%; margin: 0; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
          background: #121212; color: #f5f5f5;
          display: flex; align-items: center; justify-content: center;
        }
        .card { text-align: center; padding: 56px 48px; max-width: 420px; }
        .badge {
          width: 64px; height: 64px; border-radius: 16px; background: #FDB817;
          display: flex; align-items: center; justify-content: center; margin: 0 auto 24px;
        }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 8px; }
        p { font-size: 14px; line-height: 1.5; color: #a3a3a3; margin: 0; }
        .brand { margin-top: 32px; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: #FDB817; font-weight: 600; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="badge">
          <svg width="38" height="38" viewBox="0 0 54 54" xmlns="http://www.w3.org/2000/svg">
            <g transform="translate(4,4) scale(2.3)" fill="#121212" stroke="#121212" stroke-width="0.5" stroke-linejoin="round" stroke-linecap="round">
              <path d="m2.5 6c0-.6.4-1 1-1h10.6l-1.4 1.4c-.4.4-.4 1.1 0 1.4.6.6 1.2.2 1.4 0l3.1-3.1c.4-.4.4-1 0-1.4l-3.1-3.1c-.4-.4-1-.4-1.4 0s-.4 1 0 1.4l1.4 1.4h-10.6c-1.7 0-3 1.3-3 3v4.5c0 .6.4 1 1 1s1-.4 1-1z"/>
              <path d="m18.5 8.5c-.6 0-1 .4-1 1v4.5c0 .6-.4 1-1 1h-10.6l1.4-1.4c.4-.4.4-1 0-1.4s-1-.4-1.4 0l-3.1 3.1c-.4.4-.4 1 0 1.4l3.1 3.1c.6.6 1.2.2 1.4 0 .4-.4.4-1 0-1.4l-1.4-1.4h10.6c1.7 0 3-1.3 3-3v-4.5c0-.6-.4-1-1-1z"/>
            </g>
          </svg>
        </div>
        <h1>Connected</h1>
        <p>Sync Bar is connected. You can close this window and return to the app.</p>
        <div class="brand">Sync Bar</div>
      </div>
      <script>setTimeout(function () { try { window.close(); } catch (e) {} }, 800);</script>
    </body>
    </html>
    """
    // swiftlint:enable line_length

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

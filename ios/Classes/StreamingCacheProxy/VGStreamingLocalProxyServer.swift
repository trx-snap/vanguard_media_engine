// VGStreamingLocalProxyServer.swift
// Phase 4C6H2A — iOS hardened local loopback streaming proxy substrate
//
// Inspired by KTVHTTPCache local media proxy/cache architecture.
// Rewritten and hardened for Vanguard; no external Pod dependency.
//
// Design decisions vs KTV / CocoaHTTPServer reference:
//   - Uses Network.framework NWListener / NWConnection; no CocoaHTTPServer, no GCDAsyncSocket.
//   - Binds ONLY to IPv4 loopback (127.0.0.1) on an ephemeral port — never 0.0.0.0 or LAN.
//   - Original URL is never encoded in the proxy path or query string.
//   - No Bonjour advertising, no WebSocket, no multipart, no static file serving.

import Foundation
import Network

// MARK: - Server

/// Package-internal singleton.  Start is lazy; the listener is created on first call to `proxiedURL`.
final class VGStreamingLocalProxyServer {

    static let shared = VGStreamingLocalProxyServer()
    private init() {}

    private let registry = VGStreamingLocalProxyRegistry.shared
    private let queue    = DispatchQueue(label: "vg.proxy.server", qos: .utility)

    private var listener: NWListener?
    private var boundPort: UInt16 = 0

    /// Strong references to active connection handlers, keyed by opaque connection id.
    /// All access is on `queue`.
    private var activeConnections: [UUID: VGStreamingLocalProxyConnection] = [:]

    // MARK: - Start

    /// Ensure the listener is running.  Idempotent.
    /// - Throws: If NWListener cannot be created or fails to bind.
    func ensureStarted() throws {
        guard listener == nil else { return }

        // Bind exclusively to IPv4 loopback.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 0)!   // ephemeral port
        )
        // Disable Bonjour, LAN advertising.
        params.includePeerToPeer = false

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // Capture the assigned ephemeral port when listener becomes ready.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                // NWListener.port is NWEndpoint.Port? — read rawValue directly.
                if let p = self.listener?.port {
                    self.boundPort = p.rawValue
                }
            }
        }

        listener.start(queue: queue)

        // Wait briefly for the listener to bind and report its port.
        let deadline = Date().addingTimeInterval(2.0)
        while boundPort == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard boundPort != 0 else {
            self.listener?.cancel()
            self.listener = nil
            throw VGProxyError.bindFailed("Listener failed to report an ephemeral port within 2 s")
        }
    }

    // MARK: - Public API

    /// Register a proxied URL for `originalURL` and return a local proxy route.
    /// Starts the listener if not already running.
    func proxiedURL(
        for originalURL:  URL,
        headers:          [String: String]?,
        formatHint:       String,
        networkProfile:   String
    ) throws -> VGStreamingLocalProxyRoute {
        try ensureStarted()
        let token = registry.insert(
            originalURL:    originalURL,
            httpHeaders:    headers,
            formatHint:     formatHint,
            networkProfile: networkProfile
        )
        let proxyURL = baseURL().appendingPathComponent(token)
        return VGStreamingLocalProxyRoute(routeId: token, proxyURL: proxyURL)
    }

    /// Release a proxy route.  Idempotent.
    func release(routeId: String) {
        registry.release(routeId: routeId)
    }

    /// Metrics snapshot for a route.
    func metrics(routeId: String) -> [String: Any] {
        return registry.metrics(routeId: routeId)
    }

    // MARK: - Connection handler

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let base = baseURL()
        let connectionId = UUID()
        let handler = VGStreamingLocalProxyConnection(
            connection:   nwConnection,
            proxyBaseURL: base,
            registry:     registry,
            onComplete:   { [weak self] in
                // Called on `queue`; release the strong reference.
                self?.activeConnections.removeValue(forKey: connectionId)
            }
        )
        // Retain the handler until it calls onComplete.
        activeConnections[connectionId] = handler
        handler.start(queue: queue)
    }

    // MARK: - Helpers

    private func baseURL() -> URL {
        // Always loopback; port captured at bind time.
        return URL(string: "http://127.0.0.1:\(boundPort)/vanguard/")!
    }
}

// MARK: - Error

enum VGProxyError: Error {
    case bindFailed(String)
}

import Foundation
import Network

@MainActor final class LocalPWAServer {
    private static let maximumPortAttempts = 20

    private let queue = DispatchQueue(label: "com.metria.local-pwa-server")
    private var listener: NWListener?
    private var requestedPort: UInt16 = 0
    private var attempts = 0
    private(set) var port: UInt16?
    private var snapshot: Data?
    private var validSnapshotTokens: Set<String> = []
    var onURLChange: (() -> Void)?

    var baseURL: URL? {
        guard let port, let address = LocalNetwork.primaryIPv4Address() else { return nil }
        return URL(string: "http://\(address):\(port)")
    }

    func start(preferredPort: UInt16) {
        stop()
        requestedPort = preferredPort
        attempts = 0
        startListener()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    func updateSnapshot(_ snapshot: Data) {
        self.snapshot = snapshot
    }

    /// Accepts the legacy base64url master secret (still sent by deployed PWA installs)
    /// alongside the newer per-purpose local token (`PairingSecret.localToken`), so a
    /// header captured on the LAN cannot also unlock the ntfy relay.
    func setSnapshotTokens(_ tokens: Set<String>) {
        validSnapshotTokens = tokens.filter { !$0.isEmpty }
    }

    private func startListener() {
        guard attempts < Self.maximumPortAttempts,
              let port = NWEndpoint.Port(rawValue: requestedPort) else { return }
        attempts += 1

        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.service = NWListener.Service(name: "Metria", type: "_metria._tcp")
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                let owner = self
                let currentListener = listener
                Task { @MainActor in
                    guard let owner, let currentListener, owner.listener === currentListener else { return }
                    switch state {
                    case .ready:
                        owner.port = currentListener.port?.rawValue
                        owner.onURLChange?()
                    case .failed:
                        owner.listener?.cancel()
                        owner.listener = nil
                        owner.port = nil
                        guard owner.requestedPort < UInt16.max else { return }
                        owner.requestedPort += 1
                        owner.startListener()
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                let owner = self
                Task { @MainActor in owner?.handle(connection) }
            }
            listener.start(queue: queue)
        } catch {
            guard requestedPort < UInt16.max else { return }
            requestedPort += 1
            startListener()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let owner = self
            Task { @MainActor in
                guard let owner else {
                    connection.send(content: Self.response(status: "500 Internal Server Error", body: Data()), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let response = owner.response(for: data)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func response(for requestData: Data?) -> Data {
        guard let requestData,
              let request = String(data: requestData, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return Self.response(status: "400 Bad Request", body: Data())
        }

        let components = requestLine.split(separator: " ", maxSplits: 2)
        guard components.count >= 2, components[0] == "GET" else {
            return Self.response(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain")
        }

        let rawPath = components[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        if rawPath == "/snapshot" {
            let snapshotToken = request.components(separatedBy: "\r\n")
                .dropFirst()
                .first { $0.lowercased().hasPrefix("x-metria-secret:") }
                .flatMap { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } }
            guard let snapshotToken, !validSnapshotTokens.isEmpty, validSnapshotTokens.contains(snapshotToken), let snapshot else {
                return Self.response(status: "204 No Content", body: Data())
            }
            return Self.response(status: "200 OK", body: snapshot, contentType: "application/json; charset=utf-8")
        }
        let resourceName: String
        switch rawPath {
        case "/", "/index.html": resourceName = "index.html"
        default:
            resourceName = String(rawPath.drop(while: { $0 == "/" }))
        }
        guard !resourceName.contains(".."),
              let resourceURL = MetriaResources.bundle.url(forResource: resourceName, withExtension: nil),
              let body = try? Data(contentsOf: resourceURL) else {
            return Self.response(status: "404 Not Found", body: Data("Not Found".utf8), contentType: "text/plain")
        }
        return Self.response(status: "200 OK", body: body, contentType: Self.contentType(for: resourceName))
    }

    nonisolated private static func response(status: String, body: Data, contentType: String = "text/plain; charset=utf-8") -> Data {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(headers.utf8) + body
    }

    nonisolated private static func contentType(for resourceName: String) -> String {
        switch resourceName.split(separator: ".").last {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js": "application/javascript; charset=utf-8"
        case "json": "application/manifest+json; charset=utf-8"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }
}

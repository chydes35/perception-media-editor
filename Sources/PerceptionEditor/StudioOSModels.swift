import Foundation

/// A paired Studio OS: the API address, optionally the web address, and the device token.
struct StudioOSConnection: Equatable, Sendable {
    var serverURL: URL
    var webURL: URL?
    var token: String
}

enum StudioOSPairingError: LocalizedError, Equatable {
    case notAPairingLink
    case missingServer
    case invalidServer
    case insecureServer
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .notAPairingLink: "This is not a Studio OS pairing link."
        case .missingServer: "The pairing link does not name a Studio OS server."
        case .invalidServer: "The server address is not a valid http(s) address."
        case .insecureServer: "Remote servers must use https. Plain http is allowed only for this Mac (localhost)."
        case .invalidToken: "The pairing token is missing or malformed."
        }
    }
}

enum StudioOSPairing {
    static let scheme = "perceptionedit"

    static func connection(from link: URL) throws -> StudioOSConnection {
        guard link.scheme?.lowercased() == scheme,
              link.host?.lowercased() == "pair",
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        else { throw StudioOSPairingError.notAPairingLink }
        // A pairing link with no query at all is still a pairing link: it just names no server.
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let server = value("server"), !server.isEmpty else { throw StudioOSPairingError.missingServer }
        return try validate(server: server, web: value("web"), token: value("token") ?? "")
    }

    static func validate(server: String, web: String?, token: String) throws -> StudioOSConnection {
        let serverURL = try baseURL(server)
        var webURL: URL?
        if let web, !web.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webURL = try baseURL(web)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("pme_"), trimmed.count >= 20,
              !trimmed.contains(where: \.isWhitespace)
        else { throw StudioOSPairingError.invalidToken }
        return StudioOSConnection(serverURL: serverURL, webURL: webURL, token: trimmed)
    }

    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
            || lowered.hasSuffix(".localhost")
    }

    private static func baseURL(_ text: String) throws -> URL {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty
        else { throw StudioOSPairingError.invalidServer }
        // Userinfo can disguise the real host ("https://localhost:3001@evil.example"), and a
        // query or fragment has no meaning in a base address, so all of them are refused.
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw StudioOSPairingError.invalidServer }
        if scheme == "http", !isLoopback(host) { throw StudioOSPairingError.insecureServer }
        return url
    }

    /// `scheme://host[:port]` built from the URL's parts, for showing the user where photos go.
    /// Never the raw string, so nothing but the real host can appear in a confirmation.
    static func displayOrigin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        var host = (url.host ?? "").lowercased()
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }   // IPv6 literal
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }
}

// MARK: - Wire types (camelCase JSON, matching the Studio OS API)

struct StudioOSHealth: Codable, Equatable, Sendable {
    var status: String
    var api: String
    var storage: String
}

struct StudioOSDestination: Codable, Equatable, Identifiable, Sendable {
    var galleryId: String
    var bookingId: String
    var clientName: String
    var shootType: String
    var scheduledAt: Date?
    var id: String { galleryId }
}

struct StudioOSManifestItem: Codable, Equatable, Sendable {
    var clientItemId: String
    var fileName: String
    var sizeBytes: Int
    var sha256: String
    var position: Int
}

struct StudioOSCreateTransfer: Codable, Equatable, Sendable {
    var clientTransferId: String
    var galleryId: String
    var items: [StudioOSManifestItem]
}

enum StudioOSRemoteStatus: String, Codable, Sendable {
    case pending, processing, ready, failed
}

struct StudioOSRemoteItem: Codable, Equatable, Sendable {
    var clientItemId: String
    var itemId: String
    var mediaId: String
    var status: StudioOSRemoteStatus
    var publicationState: String
}

struct StudioOSRemoteTransfer: Codable, Equatable, Sendable {
    var transferId: String
    var galleryId: String
    var items: [StudioOSRemoteItem]
}

struct StudioOSUploadTarget: Codable, Equatable, Sendable {
    var uploadUrl: String
    var contentType: String
    var contentLength: Int
    var expiresInSeconds: Int
}

enum StudioOSJSON {
    /// Node's `toISOString()` includes fractional seconds; accept both forms.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unrecognised date: \(text)"
            ))
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

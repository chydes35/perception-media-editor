import Foundation

enum StudioOSError: LocalizedError, Equatable, Sendable {
    /// No response at all: the server is down, the address is wrong, or the network dropped.
    case unreachable(String)
    /// 401: the token is missing, unknown or revoked.
    case notPaired
    /// The server answered and refused. `message` is the server's own explanation.
    case rejected(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Studio OS could not be reached (\(detail))."
        case .notPaired: "This Mac is not paired with Studio OS, or its pairing was revoked."
        case .rejected(let status, let message): "Studio OS refused the request (\(status)): \(message)"
        case .invalidResponse: "Studio OS sent a response this app does not understand."
        }
    }
}

protocol StudioOSAPI: Sendable {
    func health() async throws -> StudioOSHealth
    func destinations() async throws -> [StudioOSDestination]
    func createTransfer(_ request: StudioOSCreateTransfer) async throws -> StudioOSRemoteTransfer
    func uploadURL(transferID: String, itemID: String) async throws -> StudioOSUploadTarget
    func upload(file: URL, to target: StudioOSUploadTarget) async throws
    func complete(transferID: String, itemID: String) async throws -> StudioOSRemoteItem
    func transferStatus(transferID: String) async throws -> StudioOSRemoteTransfer
}

struct StudioOSClient: StudioOSAPI {
    let connection: StudioOSConnection
    let session: URLSession

    init(connection: StudioOSConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    func health() async throws -> StudioOSHealth {
        try await send("GET", "health")
    }

    func destinations() async throws -> [StudioOSDestination] {
        try await send("GET", "destinations")
    }

    func createTransfer(_ request: StudioOSCreateTransfer) async throws -> StudioOSRemoteTransfer {
        try await send("POST", "transfers", body: try StudioOSJSON.makeEncoder().encode(request))
    }

    func uploadURL(transferID: String, itemID: String) async throws -> StudioOSUploadTarget {
        try await send("POST", "transfers/\(transferID)/items/\(itemID)/upload-url")
    }

    func complete(transferID: String, itemID: String) async throws -> StudioOSRemoteItem {
        try await send("POST", "transfers/\(transferID)/items/\(itemID)/complete")
    }

    func transferStatus(transferID: String) async throws -> StudioOSRemoteTransfer {
        try await send("GET", "transfers/\(transferID)")
    }

    /// Streams the file from disk. The presigned URL is for the storage host, so the
    /// Studio OS bearer token is deliberately not attached.
    func upload(file: URL, to target: StudioOSUploadTarget) async throws {
        guard let url = URL(string: target.uploadUrl) else { throw StudioOSError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(target.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform { try await session.upload(for: request, fromFile: file) }
        guard let http = response as? HTTPURLResponse else { throw StudioOSError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw StudioOSError.rejected(status: http.statusCode, message: Self.message(from: data, status: http.statusCode))
        }
    }

    // MARK: - Plumbing

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(
            url: connection.serverURL.appendingPathComponent("integrations/perception-edit/v1/\(path)")
        )
        request.httpMethod = method
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw StudioOSError.invalidResponse }
        if http.statusCode == 401 { throw StudioOSError.notPaired }
        guard (200..<300).contains(http.statusCode) else {
            throw StudioOSError.rejected(status: http.statusCode, message: Self.message(from: data, status: http.statusCode))
        }
        do {
            return try StudioOSJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw StudioOSError.invalidResponse
        }
    }

    private func perform(_ operation: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        do {
            return try await operation()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw StudioOSError.unreachable(error.localizedDescription)
        }
    }

    /// Nest errors are `{statusCode, message}` where `message` is a string or a list of strings.
    private static func message(from data: Data, status: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HTTPURLResponse.localizedString(forStatusCode: status)
        }
        if let text = object["message"] as? String { return text }
        if let list = object["message"] as? [String] { return list.joined(separator: "; ") }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}

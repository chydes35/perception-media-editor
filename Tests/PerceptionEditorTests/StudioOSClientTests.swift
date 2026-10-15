import Foundation
import Testing
@testable import PerceptionEditor

@Suite(.serialized)
struct StudioOSClientTests {
    private let token = "pme_" + String(repeating: "t", count: 43)

    private func client() -> StudioOSClient {
        StudioOSClient(
            connection: StudioOSConnection(
                serverURL: URL(string: "http://localhost:3001")!, webURL: nil, token: token
            ),
            session: stubbedSession()
        )
    }

    @Test func healthSendsTheBearerTokenToTheVersionedPath() async throws {
        StubURLProtocol.handler = { request, _ in
            #expect(request.url?.path == "/integrations/perception-edit/v1/health")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(self.token)")
            return (
                httpResponse(request.url!, status: 200),
                Data(#"{"status":"ok","api":"ok","storage":"unavailable"}"#.utf8)
            )
        }
        let health = try await client().health()
        #expect(health == StudioOSHealth(status: "ok", api: "ok", storage: "unavailable"))
    }

    @Test func mapsStatusCodesToDistinctErrors() async {
        StubURLProtocol.handler = { request, _ in (httpResponse(request.url!, status: 401), Data()) }
        await #expect(throws: StudioOSError.notPaired) { try await client().health() }

        StubURLProtocol.handler = { request, _ in
            (httpResponse(request.url!, status: 400),
             Data(#"{"statusCode":400,"message":"The uploaded file is not a JPEG"}"#.utf8))
        }
        await #expect(throws: StudioOSError.rejected(status: 400, message: "The uploaded file is not a JPEG")) {
            try await client().complete(transferID: "t", itemID: "i")
        }

        StubURLProtocol.handler = { request, _ in
            (httpResponse(request.url!, status: 400),
             Data(#"{"statusCode":400,"message":["items must not be empty","bad id"]}"#.utf8))
        }
        await #expect(throws: StudioOSError.rejected(status: 400, message: "items must not be empty; bad id")) {
            try await client().complete(transferID: "t", itemID: "i")
        }

        StubURLProtocol.handler = { _, _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client().health()
            Issue.record("expected an unreachable error")
        } catch let error as StudioOSError {
            guard case .unreachable = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func createTransferEncodesTheManifestAndDecodesTheState() async throws {
        let request = StudioOSCreateTransfer(
            clientTransferId: "pme-0001-aaaa", galleryId: "gal_1",
            items: [StudioOSManifestItem(
                clientItemId: "asset-1", fileName: "a.jpg", sizeBytes: 123,
                sha256: String(repeating: "a", count: 64), position: 0
            )]
        )
        StubURLProtocol.handler = { urlRequest, body in
            #expect(urlRequest.httpMethod == "POST")
            #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let sent = try? StudioOSJSON.makeDecoder().decode(StudioOSCreateTransfer.self, from: body ?? Data())
            #expect(sent == request)
            return (httpResponse(urlRequest.url!, status: 201), Data("""
            {"transferId":"tr_1","galleryId":"gal_1","items":[
              {"clientItemId":"asset-1","itemId":"it_1","mediaId":"m_1","status":"pending","publicationState":"draft"}]}
            """.utf8))
        }
        let state = try await client().createTransfer(request)
        #expect(state.transferId == "tr_1")
        #expect(state.items.first?.status == .pending)
    }

    @Test func uploadPutsTheFileWithoutTheBearerToken() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("photo.jpg")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        StubURLProtocol.handler = { request, body in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.host == "storage.test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
            if let body { #expect(body == bytes) }
            return (httpResponse(request.url!, status: 200), Data())
        }
        try await client().upload(
            file: file,
            to: StudioOSUploadTarget(
                uploadUrl: "https://storage.test/drafts/x?X-Amz-Signature=abc",
                contentType: "image/jpeg", contentLength: bytes.count, expiresInSeconds: 3600
            )
        )
    }

    @Test func anExpiredUploadURLIsARejectedError() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("p.jpg")
        try Data([1, 2, 3]).write(to: file)
        StubURLProtocol.handler = { request, _ in (httpResponse(request.url!, status: 403), Data("<Error/>".utf8)) }
        do {
            try await client().upload(
                file: file,
                to: StudioOSUploadTarget(uploadUrl: "https://storage.test/x", contentType: "image/jpeg", contentLength: 3, expiresInSeconds: 1)
            )
            Issue.record("expected a rejection")
        } catch let error as StudioOSError {
            guard case .rejected(let status, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(status == 403)
        }
    }
}

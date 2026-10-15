import Foundation
import Testing
@testable import PerceptionEditor

struct StudioOSPairingTests {
    private let goodToken = "pme_" + String(repeating: "a", count: 43)

    @Test func parsesAPairingLinkForALocalServer() throws {
        let link = URL(string:
            "perceptionedit://pair?server=http%3A%2F%2Flocalhost%3A3001&web=http%3A%2F%2Flocalhost%3A3000&token=\(goodToken)")!
        let connection = try StudioOSPairing.connection(from: link)
        #expect(connection.serverURL.absoluteString == "http://localhost:3001")
        #expect(connection.webURL?.absoluteString == "http://localhost:3000")
        #expect(connection.token == goodToken)
    }

    @Test func rejectsLinksThatAreNotPairingLinks() {
        for text in [
            "https://example.com/pair?server=https://x.test&token=\(goodToken)",
            "perceptionedit://other?server=https%3A%2F%2Fx.test&token=\(goodToken)",
            "perceptionedit://pair",
        ] {
            #expect(throws: StudioOSPairingError.self) {
                try StudioOSPairing.connection(from: URL(string: text)!)
            }
        }
    }

    @Test func requiresHTTPSForRemoteServersButAllowsLoopbackHTTP() throws {
        #expect(throws: StudioOSPairingError.insecureServer) {
            try StudioOSPairing.validate(server: "http://studio.example.com", web: nil, token: goodToken)
        }
        #expect(throws: StudioOSPairingError.insecureServer) {
            try StudioOSPairing.validate(server: "http://192.168.1.20:3001", web: nil, token: goodToken)
        }
        _ = try StudioOSPairing.validate(server: "https://studio.example.com/", web: nil, token: goodToken)
        _ = try StudioOSPairing.validate(server: "http://127.0.0.1:3001", web: nil, token: goodToken)
        _ = try StudioOSPairing.validate(server: "http://[::1]:3001", web: nil, token: goodToken)
    }

    @Test func rejectsBadServersAndTokens() {
        #expect(throws: StudioOSPairingError.invalidServer) {
            try StudioOSPairing.validate(server: "ftp://example.com", web: nil, token: goodToken)
        }
        #expect(throws: StudioOSPairingError.invalidServer) {
            try StudioOSPairing.validate(server: "not a url", web: nil, token: goodToken)
        }
        for bad in ["", "   ", "abc", "pme_short", "pme_ has space and is long enough to pass length"] {
            #expect(throws: StudioOSPairingError.invalidToken) {
                try StudioOSPairing.validate(server: "https://studio.example.com", web: nil, token: bad)
            }
        }
    }

    @Test func normalisesTrailingSlashesAndTrimsTheToken() throws {
        let connection = try StudioOSPairing.validate(
            server: " https://studio.example.com// ", web: "https://app.example.com/",
            token: "  \(goodToken)\n"
        )
        #expect(connection.serverURL.absoluteString == "https://studio.example.com")
        #expect(connection.webURL?.absoluteString == "https://app.example.com")
        #expect(connection.token == goodToken)
    }

    @Test func inMemoryCredentialStoreRoundTrips() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.loadToken() == nil)
        try store.saveToken(goodToken)
        #expect(try store.loadToken() == goodToken)
        try store.deleteToken()
        #expect(try store.loadToken() == nil)
    }

    @Test func decodesServerDatesWithAndWithoutFractionalSeconds() throws {
        let json = Data("""
        [{"galleryId":"g1","bookingId":"b1","clientName":"A","shootType":"Wedding","scheduledAt":"2026-10-15T12:30:00.000Z"},
         {"galleryId":"g2","bookingId":"b2","clientName":"B","shootType":"Portrait","scheduledAt":null},
         {"galleryId":"g3","bookingId":"b3","clientName":"C","shootType":"Event","scheduledAt":"2026-10-15T12:30:00Z"}]
        """.utf8)
        let decoded = try StudioOSJSON.makeDecoder().decode([StudioOSDestination].self, from: json)
        #expect(decoded.map(\.id) == ["g1", "g2", "g3"])
        #expect(decoded[0].scheduledAt != nil && decoded[1].scheduledAt == nil && decoded[2].scheduledAt != nil)
    }
}

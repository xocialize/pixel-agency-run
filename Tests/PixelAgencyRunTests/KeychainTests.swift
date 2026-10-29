import Foundation
import MESClientKit
import MESCore
@testable import PixelAgencyRun
import Testing

// The Keychain store against the real login keychain, under a prefix of its own that the test removes again.

func pairedEngine(_ id: String) throws -> PairedEngine {
    let json = """
        {"engine_id": "\(id)", "engine_name": "Keychain Test \(id)", "base_url": "https://127.0.0.1:7443/mes/v0",
         "fingerprint_sha256": "\(String(repeating: "ab", count: 32))", "token": "tok_\(id)", "client_id": "cli_test"}
        """
    return try MESJSON.decoder.decode(PairedEngine.self, from: Data(json.utf8))
}

@Suite("The Keychain credential store", .serialized)
struct KeychainCredentialStoreTests {
    // v0.4.0 asked for every item's data in one query, which the file-based keychain refuses (errSecParam), so a
    // pairing saved a moment earlier read back as none: never shown as paired, and lost on relaunch.
    @Test("Saved pairings read back, one or several; remove deletes them")
    func pairingsReadBack() throws {
        let store = KeychainCredentialStore(prefix: "PixelAgency.LiteTest.\(UUID().uuidString)")
        let engines = try ["eng_a", "eng_b"].map(pairedEngine)
        defer { for engine in engines { try? store.remove(engineID: engine.engineID) } }

        #expect(store.pairings().isEmpty)
        try store.save(engines[0])
        #expect(store.pairings() == [engines[0]])
        try store.save(engines[1])
        #expect(store.pairings().sorted { $0.engineID < $1.engineID } == engines)

        var renewed = engines[1]
        renewed.token = "tok_renewed"
        try store.save(renewed)
        #expect(store.pairings().first { $0.engineID == renewed.engineID } == renewed)

        try store.remove(engineID: engines[0].engineID)
        #expect(store.pairings() == [renewed])
        try store.remove(engineID: engines[1].engineID)
        #expect(store.pairings().isEmpty)
    }
}

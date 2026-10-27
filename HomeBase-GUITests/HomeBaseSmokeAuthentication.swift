import Foundation
import XCTest
@testable import HomeBase_GUI

/// Used only by explicitly enabled camera smoke tests. A dedicated invitation
/// creates one test identity, retained in the test host's device-only Keychain
/// and reused by the remaining smoke cases and subsequent runs.
@MainActor
enum HomeBaseSmokeAuthentication {
    private static let servers = PairedServerStore(storageKey: "authenticationSmokeServers",
        selectionStorageKey: "authenticationSmokeServerID", didRemoveServer: { _ in })

    static func client(pairingURL: String) async throws -> HomeBaseWebSocketClient {
        guard let invitation = HomeBasePairingCode.invitation(from: pairingURL) else {
            throw HomeBaseAuthenticationError.invalidPairingURL
        }
        let server = try await servers.add(invitation)
        return HomeBaseWebSocketClient(endpoint: server.endpoint, clientID: server.id, bluetoothServerID: server.id)
    }
}

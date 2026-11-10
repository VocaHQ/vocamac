// KeychainCredentialStoreTests.swift
// VocaMac Tests
//
// Endpoint API keys in the login Keychain, under a test-only service name
// so a real saved key is never read or replaced.

import Security
import XCTest
@testable import VocaMac

final class KeychainCredentialStoreTests: XCTestCase {
    private var store: KeychainCredentialStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = KeychainCredentialStore(
            service: "com.vocamac.tests.keychain-\(UUID().uuidString)", account: "api-key"
        )
        // CI runners and sandboxes may have no usable login Keychain.
        do {
            try store.saveAPIKey("probe")
            try store.deleteAPIKey()
        } catch {
            throw XCTSkip("No writable Keychain here: \(error.localizedDescription)")
        }
    }

    override func tearDownWithError() throws {
        try? store?.deleteAPIKey()
        try super.tearDownWithError()
    }

    func testSavesReadsReplacesAndDeletes() throws {
        XCTAssertNil(store.readAPIKey())

        try store.saveAPIKey("  sk-first \n")
        XCTAssertEqual(store.readAPIKey(), "sk-first", "Saved trimmed")

        try store.saveAPIKey("sk-second")
        XCTAssertEqual(store.readAPIKey(), "sk-second", "An existing item is updated, not duplicated")

        try store.deleteAPIKey()
        XCTAssertNil(store.readAPIKey())
    }

    func testSavingABlankKeyDeletesIt() throws {
        try store.saveAPIKey("sk-key")
        try store.saveAPIKey("   ")
        XCTAssertNil(store.readAPIKey())
    }

    func testDeletingAMissingKeyIsNotAnError() {
        XCTAssertNoThrow(try store.deleteAPIKey())
    }

    func testStoresDoNotShareKeys() throws {
        let other = KeychainCredentialStore(service: store.service, account: "other-account")
        defer { try? other.deleteAPIKey() }
        try store.saveAPIKey("sk-mine")
        XCTAssertNil(other.readAPIKey())
    }
}

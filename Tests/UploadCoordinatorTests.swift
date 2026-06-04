//
//  UploadCoordinatorTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

@MainActor
final class UploadCoordinatorTests: XCTestCase {

    func test_unsupported_only_drop_shows_error_banner_without_uploading() {
        let coordinator = UploadCoordinator.shared
        let url = URL(fileURLWithPath: "/tmp/not-a-doc-\(UUID().uuidString).txt")

        coordinator.upload(urls: [url], toFolderId: "")

        XCTAssertFalse(coordinator.isUploading, "an all-unsupported batch should never start uploading")
        XCTAssertEqual(coordinator.banner?.kind, .error)
        XCTAssertEqual(coordinator.banner?.count, 1)
    }

    func test_remarkable_health_flips_on_token_rejection_only() {
        let ledger = Ledger.shared
        ledger.setRemarkableNeedsRepair(false)

        // A dead device token marks the connection as needing repair.
        ledger.updateRemarkableHealth(error: RemarkableError.tokenRejected)
        XCTAssertTrue(ledger.remarkableNeedsRepair)

        // A transient error (offline, rate-limited) leaves it unchanged.
        ledger.updateRemarkableHealth(error: RemarkableError.network("offline"))
        XCTAssertTrue(ledger.remarkableNeedsRepair)

        // A clean result clears it.
        ledger.updateRemarkableHealth(error: nil)
        XCTAssertFalse(ledger.remarkableNeedsRepair)
    }
}

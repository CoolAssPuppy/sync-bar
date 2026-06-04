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
}

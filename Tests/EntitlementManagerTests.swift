//
//  EntitlementManagerTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The entitlement state machine and the daily-check midnight math, both pure so
//  they test without the keychain or network. The grace rule is the heart: a
//  network blip never locks out a payer before expiresAt.
//

import XCTest
@testable import SyncBar

final class EntitlementManagerTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int,
                      zone: String = "America/Los_Angeles") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func record(_ state: LicenseStatus.State, expiresAt: Date? = nil) -> EntitlementRecord {
        EntitlementRecord(statusRaw: state.rawValue, expiresAt: expiresAt, customerId: "cus", lastValidatedAt: nil)
    }

    // MARK: Midnight math

    func test_secondsUntilNextMidnight_one_hour_before_midnight_pacific() {
        let now = date(2026, 6, 29, 23, 0)
        let seconds = EntitlementManager.secondsUntilNextMidnight(after: now, in: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(seconds, 3600, accuracy: 1)
    }

    func test_secondsUntilNextMidnight_just_after_midnight_is_nearly_a_full_day() {
        let now = date(2026, 6, 29, 0, 1)
        let seconds = EntitlementManager.secondsUntilNextMidnight(after: now, in: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(seconds, 24 * 3600 - 60, accuracy: 1)
    }

    func test_secondsUntilNextMidnight_is_always_positive() {
        let now = date(2026, 6, 29, 0, 0)   // exactly midnight -> next is tomorrow
        let seconds = EntitlementManager.secondsUntilNextMidnight(after: now, in: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertGreaterThan(seconds, 0)
    }

    // MARK: Derived gate

    func test_granted_without_expiry_is_entitled() {
        XCTAssertTrue(EntitlementManager.isEntitled(record: record(.granted), now: date(2026, 6, 29, 12, 0)))
    }

    func test_granted_before_expiry_is_entitled() {
        let now = date(2026, 6, 29, 12, 0)
        let rec = record(.granted, expiresAt: date(2026, 7, 29, 12, 0))
        XCTAssertTrue(EntitlementManager.isEntitled(record: rec, now: now))
    }

    func test_granted_after_expiry_fails_closed() {
        let now = date(2026, 6, 29, 12, 0)
        let rec = record(.granted, expiresAt: date(2026, 6, 1, 12, 0))
        XCTAssertFalse(EntitlementManager.isEntitled(record: rec, now: now))
    }

    func test_revoked_disabled_unknown_and_nil_are_not_entitled() {
        let now = date(2026, 6, 29, 12, 0)
        XCTAssertFalse(EntitlementManager.isEntitled(record: record(.revoked), now: now))
        XCTAssertFalse(EntitlementManager.isEntitled(record: record(.disabled), now: now))
        XCTAssertFalse(EntitlementManager.isEntitled(record: record(.unknown), now: now))
        XCTAssertFalse(EntitlementManager.isEntitled(record: nil, now: now))
    }

    // MARK: Grace / lapse (reduce)

    func test_successful_validate_replaces_the_record() {
        let now = date(2026, 6, 29, 12, 0)
        let status = LicenseStatus(state: .granted, expiresAt: date(2026, 7, 29, 12, 0), customerId: "cus_1")
        let updated = EntitlementManager.reduce(current: nil, result: .success(status), now: now)
        XCTAssertEqual(updated?.state, .granted)
        XCTAssertTrue(EntitlementManager.isEntitled(record: updated, now: now))
    }

    func test_network_failure_keeps_prior_record_so_payer_is_not_locked_out() {
        let now = date(2026, 6, 29, 12, 0)
        let prior = record(.granted, expiresAt: date(2026, 7, 29, 12, 0))
        let updated = EntitlementManager.reduce(current: prior,
                                                result: .failure(URLError(.notConnectedToInternet)), now: now)
        XCTAssertEqual(updated, prior)
        XCTAssertTrue(EntitlementManager.isEntitled(record: updated, now: now), "grace: a blip keeps entitlement")
    }

    func test_network_failure_after_expiry_still_fails_closed() {
        let now = date(2026, 6, 29, 12, 0)
        let expired = record(.granted, expiresAt: date(2026, 6, 1, 12, 0))
        let updated = EntitlementManager.reduce(current: expired,
                                                result: .failure(URLError(.timedOut)), now: now)
        // Record is kept, but the expiry has passed, so the gate fails closed.
        XCTAssertFalse(EntitlementManager.isEntitled(record: updated, now: now))
    }

    func test_transient_server_error_keeps_prior_record() {
        let now = date(2026, 6, 29, 12, 0)
        let prior = record(.granted, expiresAt: date(2026, 7, 29, 12, 0))
        let updated = EntitlementManager.reduce(current: prior,
                                                result: .failure(LicenseError.requestFailed(status: 500, message: "boom")), now: now)
        XCTAssertEqual(updated, prior)
    }

    func test_invalid_key_lapses_immediately() {
        let now = date(2026, 6, 29, 12, 0)
        let prior = record(.granted, expiresAt: date(2026, 7, 29, 12, 0))
        let updated = EntitlementManager.reduce(current: prior,
                                                result: .failure(LicenseError.invalidKey), now: now)
        XCTAssertEqual(updated?.state, .revoked)
        XCTAssertFalse(EntitlementManager.isEntitled(record: updated, now: now))
    }

    // MARK: Feature mapping (optionality)

    func test_twitter_is_the_paid_class_for_x_and_other_sources_are_free() {
        XCTAssertEqual(SourceKind.x.paidFeature, .twitter)
        XCTAssertNil(SourceKind.safari.paidFeature)
        XCTAssertNil(SourceKind.remarkable.paidFeature)
        XCTAssertNil(SourceKind.notion.paidFeature)
    }
}

//
//  TelemetryBypassTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

/// The opt-out is sacred for normal analytics, with exactly one exception: a
/// paid Sync class's usage metering (`bypassOptOut: true`), which the user
/// consents to when adding the source. These tests pin both halves of that rule.
final class TelemetryBypassTests: XCTestCase {

    override func tearDown() {
        Telemetry.testHook = nil
        // Restore the default (unset == opted in) so we never leave the real
        // app's analytics preference flipped.
        UserDefaults.standard.removeObject(forKey: Telemetry.optInKey)
        super.tearDown()
    }

    /// Captures the event names emitted for a given opt-in state and bypass flag.
    private func emittedEvents(optedIn: Bool, bypassOptOut: Bool) -> [String] {
        UserDefaults.standard.set(optedIn, forKey: Telemetry.optInKey)
        var events: [String] = []
        Telemetry.testHook = { event, _ in events.append(event) }
        Telemetry.capture("test.event", bypassOptOut: bypassOptOut)
        return events
    }

    func test_optedIn_capturesNormalEvent() {
        XCTAssertEqual(emittedEvents(optedIn: true, bypassOptOut: false), ["test.event"])
    }

    func test_optedOut_dropsNormalEvent() {
        XCTAssertEqual(emittedEvents(optedIn: false, bypassOptOut: false), [])
    }

    func test_optedOut_bypassEmitsAnyway() {
        XCTAssertEqual(emittedEvents(optedIn: false, bypassOptOut: true), ["test.event"])
    }

    func test_optedIn_bypassStillEmits() {
        XCTAssertEqual(emittedEvents(optedIn: true, bypassOptOut: true), ["test.event"])
    }

    func test_capturedEvent_carriesSourceAndVersion() {
        UserDefaults.standard.set(true, forKey: Telemetry.optInKey)
        var props: [String: Any] = [:]
        Telemetry.testHook = { _, p in props = p }
        Telemetry.capture("test.event", properties: ["k": "v"])
        XCTAssertEqual(props["k"] as? String, "v")
        // source/app_version are attached from Info.plist automatically.
        XCTAssertNotNil(props["app_version"])
    }
}

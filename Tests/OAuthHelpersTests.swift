//
//  OAuthHelpersTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

final class OAuthHelpersTests: XCTestCase {

    func test_redirectURI_uses_app_scheme_and_provider() {
        XCTAssertEqual(OAuth.redirectURI(provider: "linear"), "syncbar://oauth/linear")
        XCTAssertEqual(OAuth.redirectURI(provider: "notion"), "syncbar://oauth/notion")
    }

    func test_formURLEncoding_escapes_reserved_characters() {
        let body = OAuth.formURLEncoded(["grant_type": "authorization_code", "code": "a+b/c=d&e"])
        let text = String(bytes: body, encoding: .utf8) ?? ""
        // The two fields are joined by a literal & ...
        let pairs = text.split(separator: "&").map(String.init)
        XCTAssertEqual(pairs.count, 2)
        // ... and reserved characters inside a value are percent-encoded, not literal.
        XCTAssertTrue(pairs.contains("grant_type=authorization_code"))
        XCTAssertTrue(pairs.contains("code=a%2Bb%2Fc%3Dd%26e"))
    }

    func test_randomState_is_url_safe_and_unique() {
        let a = OAuth.randomState()
        let b = OAuth.randomState()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        let illegal = CharacterSet(charactersIn: "+/=")
        XCTAssertNil(a.rangeOfCharacter(from: illegal), "state must be base64url (no +, /, =)")
    }

    func test_queryValue_extracts_code_and_state_from_callback() {
        let url = URL(staticString: "syncbar://oauth/linear?code=abc123&state=xyz")
        XCTAssertEqual(OAuth.queryValue("code", from: url), "abc123")
        XCTAssertEqual(OAuth.queryValue("state", from: url), "xyz")
        XCTAssertNil(OAuth.queryValue("missing", from: url))
    }

    func test_base64URL_encoding_strips_padding_and_substitutes() {
        let data = Data([0xfb, 0xff, 0xfe])  // base64 "+//+" -> url "-__-"
        XCTAssertEqual(data.base64URLEncodedString(), "-__-")
    }
}

//
//  GoogleAuthServiceTests.swift
//  SyncBarTests
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import XCTest
@testable import SyncBar

@MainActor
final class GoogleAuthServiceTests: XCTestCase {

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func test_authorizeURL_carries_pkce_and_offline_params() {
        let url = GoogleAuthService.authorizeURL(clientId: "g-client", state: "st", challenge: "chal")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let q = queryItems(url)
        XCTAssertEqual(q["client_id"], "g-client")
        XCTAssertEqual(q["redirect_uri"], "http://localhost:53118/oauth/google")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge"], "chal")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["state"], "st")
        XCTAssertTrue(q["scope"]?.contains("documents") == true)
        XCTAssertTrue(q["scope"]?.contains("drive.file") == true)
    }

    func test_parseTokenResponse_reads_fields() throws {
        let json = #"{"access_token":"ya29.abc","expires_in":3599,"refresh_token":"1//refresh","scope":"...","token_type":"Bearer"}"#
        let token = try GoogleTokens.parseTokenResponse(Data(json.utf8))
        XCTAssertEqual(token.access_token, "ya29.abc")
        XCTAssertEqual(token.refresh_token, "1//refresh")
        XCTAssertEqual(token.expires_in, 3599)
    }

    func test_parseTokenResponse_rejects_empty_access() {
        XCTAssertThrowsError(try GoogleTokens.parseTokenResponse(Data(#"{"access_token":""}"#.utf8)))
    }

    func test_pkceChallenge_matches_rfc7636_vector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuth.pkceChallenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func test_pkceVerifier_is_url_safe() {
        let verifier = OAuth.pkceVerifier()
        XCTAssertFalse(verifier.isEmpty)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }
}

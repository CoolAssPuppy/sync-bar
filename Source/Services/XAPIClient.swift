//
//  XAPIClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  The X (Twitter) API v2 read client and the neutral content model every X
//  object normalizes into. `XContent` is the Sync Bar-internal shape the spec
//  calls for — destinations never see an X-specific response, only the
//  normalized object (carried onward as a `SourceItem` + `NoteContent`).
//
//  Streams (bookmarks / likes / posts) each map onto a `/2/users/{id}/…`
//  endpoint that returns tweets newest-first, page by page. The pure parsing
//  lives in `parseTimeline` so it can be unit-tested without the network; the
//  pagination/stop-at-synced loop lives in `XSourceClient`.
//

import Foundation

// MARK: - Normalized content model

/// The author of an X object, normalized.
struct XAuthor: Equatable, Sendable, Hashable {
    var id: String
    var username: String
    var displayName: String

    /// The conventional @handle for display.
    var handle: String { username.hasPrefix("@") ? username : "@\(username)" }
}

/// One X object normalized into Sync Bar's common content shape (the spec's
/// "internal content model"). The source adapter turns this into a `SourceItem`
/// + `NoteContent`, so every destination consumes this rather than the raw API.
struct XContent: Equatable, Sendable, Hashable {
    var id: String
    var stream: XStream
    var text: String
    var createdAt: Date
    var author: XAuthor
    var canonicalURL: URL?
    var outboundLinks: [URL]
    var conversationId: String?
    var referencedTweetIds: [String]
    var metrics: [String: Int]
    /// Attached images: photos by their full-size URL, videos/GIFs by their
    /// preview frame (the playable asset isn't exposed by the v2 read API).
    var mediaURLs: [URL] = []

    /// Canonical permalink for a tweet, given its author handle. Falls back to
    /// the handle-less `/i/web/status/` form X also resolves.
    static func canonicalURL(tweetId: String, username: String) -> URL? {
        let handle = username.isEmpty ? "i/web" : username
        return URL(string: "https://x.com/\(handle)/status/\(tweetId)")
    }
}

/// One page of a timeline: the normalized items plus the opaque cursor for the
/// next (older) page, or nil when the timeline is exhausted.
struct XTimelinePage: Equatable, Sendable {
    var items: [XContent]
    var nextToken: String?
}

// MARK: - Errors

enum XAPIError: LocalizedError, Sendable {
    case notAuthorized
    case rateLimited
    case requestFailed(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "X sign-in has expired. Reconnect the account."
        case .rateLimited:
            return "X is rate-limiting requests. Sync Bar will retry on the next cycle."
        case .requestFailed(let status, let message):
            return "X request failed (HTTP \(status)): \(message)"
        case .invalidResponse(let message):
            return message
        }
    }
}

// MARK: - Client

/// Reads X timelines (one page per call) and normalizes them. Stateless and
/// `Sendable`; the caller supplies a valid user-context bearer token and drives
/// pagination.
struct XAPIClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static let apiBase = URL(staticString: "https://api.twitter.com/2")

    /// The tweet/user/media fields and expansions every stream requests, so the
    /// normalized object is fully populated regardless of endpoint.
    static let tweetFields = "created_at,author_id,entities,public_metrics,conversation_id,referenced_tweets,text,attachments"
    static let userFields = "username,name"
    static let expansions = "author_id,attachments.media_keys"
    static let mediaFields = "url,preview_image_url,type"

    /// Fetches one page of a stream. `paginationToken` continues a previous
    /// fetch; `sinceId` (honored only where the endpoint supports it) limits the
    /// result to tweets newer than that id.
    func page(stream: XStream,
              userId: String,
              token: String,
              paginationToken: String? = nil,
              sinceId: String? = nil,
              maxResults: Int = 100) async throws -> XTimelinePage {
        let url = try Self.pageURL(stream: stream, userId: userId,
                                   paginationToken: paginationToken,
                                   sinceId: sinceId, maxResults: maxResults)
        return try await fetch(url: url, token: token, stream: stream)
    }

    /// Fetches the author's own replies within a conversation — the thread
    /// continuations. `from:` scopes to the author and `to:` keeps only replies
    /// to their own tweets, so third-party replies (and the root, which is not a
    /// reply) never come back or bill a read. One page only; a thread longer
    /// than `maxResults` self-replies truncates silently.
    func selfReplies(conversationId: String,
                     authorId: String,
                     token: String,
                     stream: XStream) async throws -> [XContent] {
        let url = try Self.threadSearchURL(conversationId: conversationId, authorId: authorId)
        return try await fetch(url: url, token: token, stream: stream).items
    }

    /// Looks up tweets by id (used for a thread's conversation root). The plural
    /// `/2/tweets` endpoint answers with the same envelope as the timelines.
    func tweets(ids: [String], token: String, stream: XStream) async throws -> [XContent] {
        let url = try Self.tweetLookupURL(ids: ids)
        return try await fetch(url: url, token: token, stream: stream).items
    }

    /// The one networked path: authorized GET, status mapping, parse.
    private func fetch(url: URL, token: String, stream: XStream) async throws -> XTimelinePage {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401:       throw XAPIError.notAuthorized
            case 429:       throw XAPIError.rateLimited
            default:
                let snippet = String(data: data, encoding: .utf8)?.prefix(300).description ?? "HTTP \(http.statusCode)"
                throw XAPIError.requestFailed(status: http.statusCode, message: snippet)
            }
        }
        return try Self.parseTimeline(data, stream: stream)
    }

    // MARK: Pure helpers (unit-tested)

    /// Builds the request URL for a stream page.
    static func pageURL(stream: XStream,
                        userId: String,
                        paginationToken: String?,
                        sinceId: String?,
                        maxResults: Int) throws -> URL {
        var items = [URLQueryItem(name: "max_results", value: String(maxResults))]
        if let paginationToken { items.append(URLQueryItem(name: "pagination_token", value: paginationToken)) }
        // since_id only narrows endpoints that honor it; passing it elsewhere is
        // ignored by X but we keep the request clean by gating on the stream.
        if let sinceId, stream.supportsSinceId { items.append(URLQueryItem(name: "since_id", value: sinceId)) }
        return try requestURL(path: "users/\(userId)/\(stream.apiPathComponent)", queryItems: items)
    }

    /// Builds the recent-search URL that returns an author's own replies inside
    /// one conversation — the thread continuations, nobody else's replies.
    static func threadSearchURL(conversationId: String,
                                authorId: String,
                                maxResults: Int = 100) throws -> URL {
        try requestURL(path: "tweets/search/recent", queryItems: [
            URLQueryItem(name: "query", value: "conversation_id:\(conversationId) from:\(authorId) to:\(authorId)"),
            URLQueryItem(name: "max_results", value: String(maxResults))
        ])
    }

    /// Builds the plural tweet-lookup URL (`/2/tweets?ids=…`).
    static func tweetLookupURL(ids: [String]) throws -> URL {
        try requestURL(path: "tweets", queryItems: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ])
    }

    /// Every read endpoint shares the same fields/expansions so the normalized
    /// object is fully populated regardless of where a tweet came from.
    private static func requestURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = apiBase.appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = queryItems + [
            URLQueryItem(name: "tweet.fields", value: tweetFields),
            URLQueryItem(name: "expansions", value: expansions),
            URLQueryItem(name: "user.fields", value: userFields),
            URLQueryItem(name: "media.fields", value: mediaFields)
        ]
        guard let url = components.url else {
            throw XAPIError.invalidResponse("Could not build the X request URL.")
        }
        return url
    }

    // Raw decoding shapes mirroring the X API v2 timeline envelope.
    private struct Envelope: Decodable {
        struct Tweet: Decodable {
            let id: String
            let text: String
            let created_at: String?
            let author_id: String?
            let conversation_id: String?
            let entities: Entities?
            let public_metrics: [String: Int]?
            let referenced_tweets: [Referenced]?
            let attachments: Attachments?
        }
        struct Entities: Decodable { let urls: [URLEntity]? }
        struct URLEntity: Decodable { let url: String?; let expanded_url: String?; let unwound_url: String? }
        struct Referenced: Decodable { let type: String; let id: String }
        struct Attachments: Decodable { let media_keys: [String]? }
        struct User: Decodable { let id: String; let username: String; let name: String }
        struct Media: Decodable { let media_key: String; let type: String?; let url: String?; let preview_image_url: String? }
        struct Includes: Decodable { let users: [User]?; let media: [Media]? }
        struct Meta: Decodable { let next_token: String?; let result_count: Int? }
        struct APIError: Decodable { let title: String?; let detail: String? }
        let data: [Tweet]?
        let includes: Includes?
        let meta: Meta?
        let errors: [APIError]?
    }

    /// Parses one timeline page into normalized content. Tolerant of a missing
    /// `data` array (an empty page) and of partial tweets (a tweet missing its
    /// author or date still normalizes, with best-effort fallbacks).
    static func parseTimeline(_ data: Data, stream: XStream) throws -> XTimelinePage {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw XAPIError.invalidResponse("Couldn't read X's response.")
        }
        // An errors-only response with no data is a hard failure (e.g. a revoked
        // token surfaced as a 200 with an errors array).
        if (envelope.data ?? []).isEmpty, let first = envelope.errors?.first {
            let message = [first.title, first.detail].compactMap { $0 }.joined(separator: ": ")
            throw XAPIError.invalidResponse(message.isEmpty ? "X returned an error." : message)
        }

        let usersById = Dictionary(
            (envelope.includes?.users ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let mediaByKey = Dictionary(
            (envelope.includes?.media ?? []).map { ($0.media_key, $0) },
            uniquingKeysWith: { first, _ in first })

        let items: [XContent] = (envelope.data ?? []).map { tweet in
            let user = tweet.author_id.flatMap { usersById[$0] }
            let author = XAuthor(
                id: tweet.author_id ?? user?.id ?? "",
                username: user?.username ?? "",
                displayName: user?.name ?? user?.username ?? "")
            let createdAt = tweet.created_at.flatMap(Formatters.parseISO8601)
                ?? Date(timeIntervalSince1970: 0)
            let links: [URL] = (tweet.entities?.urls ?? []).compactMap { entity in
                let raw = entity.unwound_url ?? entity.expanded_url
                return raw.flatMap { URL(string: $0) }
            }
            let mediaURLs: [URL] = (tweet.attachments?.media_keys ?? []).compactMap { key in
                guard let media = mediaByKey[key] else { return nil }
                // Photos expose a full-size url; videos/GIFs only a preview frame.
                return (media.url ?? media.preview_image_url).flatMap { URL(string: $0) }
            }
            return XContent(
                id: tweet.id,
                stream: stream,
                text: expandLinks(in: tweet.text, entities: tweet.entities?.urls ?? []),
                createdAt: createdAt,
                author: author,
                canonicalURL: XContent.canonicalURL(tweetId: tweet.id, username: author.username),
                outboundLinks: dedupePreservingOrder(links),
                conversationId: tweet.conversation_id,
                referencedTweetIds: (tweet.referenced_tweets ?? []).map(\.id),
                metrics: tweet.public_metrics ?? [:],
                mediaURLs: mediaURLs)
        }
        return XTimelinePage(items: items, nextToken: envelope.meta?.next_token)
    }

    /// Rewrites t.co shorteners in the display text to the resolved link, and
    /// drops media permalinks (the trailing t.co that points back at the
    /// tweet's own /photo/N or /video/N page — the actual asset arrives via
    /// `mediaURLs` instead).
    private static func expandLinks(in text: String, entities: [Envelope.URLEntity]) -> String {
        var output = text
        for entity in entities {
            guard let short = entity.url, !short.isEmpty,
                  let resolved = entity.unwound_url ?? entity.expanded_url else { continue }
            let isMediaPermalink = resolved.contains("/photo/") || resolved.contains("/video/")
            output = output.replacingOccurrences(of: short, with: isMediaPermalink ? "" : resolved)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dedupes URLs while keeping first-seen order (a tweet can list the same
    /// expanded URL twice across entities).
    private static func dedupePreservingOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted { out.append(url) }
        return out
    }
}

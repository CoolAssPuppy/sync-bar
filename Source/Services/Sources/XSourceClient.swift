//
//  XSourceClient.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  X (Twitter) as a source. Each rule targets one content stream (bookmarks /
//  likes / posts) of one connected account; this adapts the X API v2 client to
//  `SourceClient` and owns the spec's sync model:
//
//    * Initial sync  — no cursor yet, so crawl the whole history (page by page
//      to the end) and hand every item to the pipeline.
//    * Incremental   — fetch newest-first and STOP the moment an already-synced
//      id is reached (timelines come back newest-first, so everything past that
//      point is older and already done). Update the cursor + processed set.
//
//  Dedup is by content id (never timestamps), satisfying the bookmarks endpoint
//  which exposes neither a bookmark time nor a `since_id`. Tweets are immutable,
//  so an item's version hash is just its id: the per-binding ledger writes it to
//  each destination exactly once and re-runs are idempotent.
//

import Foundation

struct XSourceClient: SourceClient {
    let kind: SourceKind = .x

    /// Account context for `listScopes` (the stream picker). The engine path
    /// reads the account from each call's `XSourceConfig` instead, so this is
    /// only set when the source-setup UI constructs the client for an account.
    private let account: XAccount?
    private let keychain: KeychainStore
    private let session: URLSession
    private let stateStore: XSyncStateStore
    /// Carries the tweet bodies from `listItems` to `content(for:)` so a stream
    /// is fetched once per cycle and reused (the same instance serves both calls
    /// within a rule run). A miss falls back to an empty body rather than a
    /// second network round-trip.
    private let cache = TweetBodyCache()

    /// Runaway guard on the initial full crawl. Generous enough to back up a
    /// realistic bookmarks/likes history in one pass; a history beyond this (or a
    /// run cut short by rate limiting) resumes on the next cycle, deduped by the
    /// processed-id set, so no item is delivered twice.
    private let maxPagesPerCrawl: Int
    /// The monthly read-cap accountant. Injectable so tests get an isolated store
    /// instead of touching the real defaults.
    private let readBudget: ReadBudget

    init(account: XAccount? = nil,
         keychain: KeychainStore = .shared,
         session: URLSession = .shared,
         stateStore: XSyncStateStore = .shared,
         maxPagesPerCrawl: Int = 250,
         readBudget: ReadBudget = ReadBudget()) {
        self.account = account
        self.keychain = keychain
        self.session = session
        self.stateStore = stateStore
        self.maxPagesPerCrawl = maxPagesPerCrawl
        self.readBudget = readBudget
    }

    // MARK: Scopes (the account's content streams)

    func listScopes() async throws -> [SourceScope] {
        let streams = account?.selectedStreams ?? XStream.allCases
        return streams.map { SourceScope(id: $0.rawValue, name: $0.label, itemCount: 0) }
    }

    // MARK: Items (one content stream)

    func listItems(config: SourceConfiguration) async throws -> [SourceItem] {
        let cfg = try xConfig(config)
        let token = try await XTokens.validAccessToken(accountId: cfg.accountId, keychain: keychain, session: session)
        let api = XAPIClient(session: session)

        let state = stateStore.state(accountId: cfg.accountId, stream: cfg.stream)
        stateStore.recordAttempt(accountId: cfg.accountId, stream: cfg.stream)
        let isInitial = state.isInitialSync

        // Monthly read cap: a flat-rate subscriber's API cost is bounded by stopping
        // crawls once the month's read budget is spent. The cursor is left untouched
        // when there's no budget, so the next cycle (or next month, after the budget
        // resets) resumes from here.
        let now = Date()
        guard readBudget.remaining(now: now) > 0 else { return [] }

        var collected: [XContent] = []
        var pageToken: String?
        var pagesFetched = 0
        // Posts the API returned — the billable unit (X charges per post read,
        // whether or not we keep it after dedup), so the cap and the meter count these.
        var reads = 0

        crawl: while pagesFetched < maxPagesPerCrawl, readBudget.remaining(now: now) > 0 {
            let page = try await api.page(
                stream: cfg.stream,
                userId: cfg.accountId,
                token: token,
                paginationToken: pageToken,
                // since_id narrows incremental fetches on endpoints that support
                // it; the stop-at-processed check below is the universal guard.
                sinceId: isInitial ? nil : state.newestSyncedId)

            pagesFetched += 1
            reads += page.items.count
            // X has already billed for this page, so charge the cap immediately —
            // not after the loop, where a later page throwing would leak the cost
            // and let a reliably-failing stream re-bill every cycle uncapped.
            readBudget.record(reads: page.items.count, now: now)

            for item in page.items {
                if !isInitial, item.id == state.newestSyncedId || state.hasProcessed(item.id) {
                    break crawl   // newest-first: everything from here on is already synced
                }
                collected.append(item)
            }

            guard let next = page.nextToken else { break }
            pageToken = next
        }

        cache.store(collected)
        // Advance the cursor to the newest item seen (first, since newest-first)
        // and fold this batch into the processed set. Only on success — a thrown
        // error above leaves the cursor untouched so the next cycle retries.
        stateStore.recordSuccess(
            accountId: cfg.accountId, stream: cfg.stream,
            newestId: collected.first?.id, processedIds: collected.map(\.id))

        await emitUsage(cfg: cfg, itemsSynced: collected.count, reads: reads,
                        pages: pagesFetched, isInitial: isInitial)

        return collected.map(Self.makeItem)
    }

    /// Emits the un-disableable usage signal after a successful crawl: an analytics
    /// event (so the maker sees who consumes the X budget) and a best-effort post
    /// to the metered-billing relay. Consented to when the source was added. The
    /// analytics event bypasses the opt-out; both never affect the sync's outcome.
    private func emitUsage(cfg: XSourceConfig, itemsSynced: Int, reads: Int, pages: Int, isInitial: Bool) async {
        let handle = cfg.username.hasPrefix("@") ? cfg.username : "@\(cfg.username)"
        let customerId = await EntitlementManager.shared.customerId(for: .twitter)
        Telemetry.capture("x.sync.usage", properties: [
            "x_user_id": cfg.accountId,
            "handle": handle,
            "stream": cfg.stream.rawValue,
            "pages_fetched": pages,
            "items_synced": itemsSynced,
            // The billable unit (posts the API returned), which is what maps to the
            // maker's X cost — distinct from items_synced (the deduped new items).
            "reads": reads,
            "is_initial_sync": isInitial,
            "license_customer_id": customerId ?? ""
        ], bypassOptOut: true)

        // Bill the reads through the relay off the sync's critical path; primitives
        // only so nothing non-Sendable crosses into the detached task.
        let licenseKey = keychain.value(for: .licenseKey)
        let accountId = cfg.accountId
        let streamRaw = cfg.stream.rawValue
        Task.detached {
            await UsageReporter().report(reads: reads, licenseKey: licenseKey, properties: [
                "x_user_id": accountId,
                "stream": streamRaw,
                "is_initial": String(isInitial)
            ])
        }
    }

    func content(for item: SourceItem, config: SourceConfiguration) async throws -> NoteContent {
        guard let tweet = cache.tweet(id: item.id) else {
            // The body wasn't cached this cycle (e.g. content() called without a
            // preceding listItems on the same instance). Fall back to whatever
            // text the item carried rather than a second network call.
            return NoteContent(blocks: Self.blocks(from: item.metadata["body"] ?? ""), provider: "x")
        }
        return NoteContent(blocks: Self.blocks(from: tweet.text), provider: "x")
    }

    func resolveTitle(for item: SourceItem,
                      content: NoteContent,
                      config: SourceConfiguration,
                      strategyOverride: TitleStrategy?) -> String {
        if !item.name.isEmpty { return item.name }
        let firstLine = content.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !firstLine.isEmpty { return Self.truncatedTitle(firstLine) }
        return "Post on X"
    }

    func shouldSkipAsEmpty(content: NoteContent,
                           config: SourceConfiguration,
                           ocrModeOverride: OcrMode?) -> Bool {
        // Every bookmark/like/post is worth mirroring, including link-only ones.
        false
    }

    // MARK: Helpers

    private func xConfig(_ config: SourceConfiguration) throws -> XSourceConfig {
        guard case .x(let cfg) = config else {
            throw SourceError.wrongConfiguration(expected: .x)
        }
        return cfg
    }

    /// Normalizes one tweet into a `SourceItem`: id-as-version (immutable), the
    /// canonical URL, and the frontmatter-friendly metadata destinations record.
    static func makeItem(_ tweet: XContent) -> SourceItem {
        SourceItem(
            id: tweet.id,
            name: title(for: tweet),
            versionHash: tweet.id,         // tweets are immutable; id is the version
            createdAt: tweet.createdAt,
            tags: [],
            url: tweet.canonicalURL,
            folderPath: [],
            metadata: metadata(for: tweet))
    }

    /// The per-item title: the first line of the tweet, truncated, with a handle
    /// fallback for media-only posts.
    static func title(for tweet: XContent) -> String {
        let firstLine = tweet.text
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !firstLine.isEmpty { return truncatedTitle(firstLine) }
        return "\(tweet.author.handle) on X"
    }

    static func truncatedTitle(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Builds the normalized key/value metadata carried to destinations (e.g.
    /// Markdown frontmatter), dropping empties so a sparse tweet stays clean.
    static func metadata(for tweet: XContent) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out: [String: String] = [
            "source": "x",
            "stream": tweet.stream.rawValue,
            "id": tweet.id,
            "author": tweet.author.handle,
            "author_name": tweet.author.displayName,
            "author_id": tweet.author.id,
            "created_at": formatter.string(from: tweet.createdAt)
        ]
        if let url = tweet.canonicalURL { out["canonical_url"] = url.absoluteString }
        if let conversationId = tweet.conversationId { out["conversation_id"] = conversationId }
        if !tweet.outboundLinks.isEmpty {
            out["outbound_links"] = tweet.outboundLinks.map(\.absoluteString).joined(separator: ", ")
        }
        for (metric, value) in tweet.metrics { out[metric] = String(value) }
        return out.filter { !$0.value.isEmpty }
    }

    /// Splits tweet text into paragraph blocks (one per non-empty line), the
    /// neutral shape every destination renders its own way.
    static func blocks(from text: String) -> [NoteBlock] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.paragraph(trimmed)]
        }
        return lines.map { .paragraph($0) }
    }
}

/// Per-cycle cache of fetched tweet bodies, keyed by id. A reference type so the
/// `XSourceClient` value can populate it in `listItems` and read it in
/// `content(for:)`. `@unchecked Sendable` with a lock to satisfy strict
/// concurrency; the two calls never run concurrently on one instance.
private final class TweetBodyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byId: [String: XContent] = [:]

    func store(_ tweets: [XContent]) {
        lock.lock(); defer { lock.unlock() }
        for tweet in tweets { byId[tweet.id] = tweet }
    }

    func tweet(id: String) -> XContent? {
        lock.lock(); defer { lock.unlock() }
        return byId[id]
    }
}

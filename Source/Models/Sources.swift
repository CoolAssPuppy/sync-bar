//
//  Sources.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  A source is a place Sync Bar pulls notes FROM. reMarkable is the only one
//  today, but the kind is modeled separately from the data layer so adding a
//  new source is a matter of a new case plus its brand mark - the UI already
//  renders any SourceKind through SourceIcon / BrandIcon.
//

import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case remarkable
    case safari
    case notion
    case x

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remarkable: return "reMarkable"
        case .safari:     return "Safari"
        case .notion:     return "Notion"
        case .x:          return "Twitter"
        }
    }

    /// One-line description for pickers and empty states.
    var subtitle: String {
        switch self {
        case .remarkable: return "Tablet notebooks and documents"
        case .safari:     return "Browser bookmarks"
        case .notion:     return "Database pages, backed up"
        case .x:          return "Bookmarks, likes, and posts"
        }
    }

    /// SF Symbol fallback when the bundled brand asset is missing.
    var systemImage: String {
        switch self {
        case .remarkable: return "rectangle.portrait.on.rectangle.portrait"
        case .safari:     return "safari"
        case .notion:     return "square.grid.3x3.fill"
        case .x:          return "bird"
        }
    }

    /// Brand asset shipped in `Images.xcassets`. Notion reuses the destination
    /// brand mark (same logo, source or destination).
    var assetName: String {
        switch self {
        case .remarkable: return "Remarkable"
        case .safari:     return "Safari"
        case .notion:     return "Destinations/Notion"
        // No brand asset: Twitter renders the `bird` SF Symbol (systemImage)
        // rather than the old X logo. An empty name fails the NSImage lookup in
        // BrandIcon, which then falls back to the symbol.
        case .x:          return ""
        }
    }

    /// Whether the brand mark is a single-color silhouette that must be tinted
    /// to stay visible across themes (see DestinationKind for the same idea).
    /// Twitter falls back to the `bird` SF Symbol, which is already tinted to the
    /// foreground in BrandIcon's symbol path, so it needs no template treatment.
    var brandMarkIsMonochrome: Bool {
        switch self {
        case .remarkable: return false
        case .safari:     return false
        case .notion:     return false
        case .x:          return false
        }
    }

    /// Whether the mark is a bare logo that needs a white chip behind it
    /// (reMarkable). App-icon sources (Safari) carry their own background and
    /// render bare and full-size, like destination icons.
    var rendersOnChip: Bool {
        switch self {
        case .remarkable: return true
        case .safari:     return false
        case .notion:     return false
        case .x:          return false
        }
    }
}

// MARK: - X content streams

/// One independently-synced X content type. Each is its own sync stream with its
/// own cursor and dedup state (see `XStreamSyncState`); a rule targets exactly
/// one. The three map onto distinct X API v2 endpoints and OAuth scopes.
enum XStream: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case bookmarks
    case likes
    case posts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bookmarks: return "Bookmarks"
        case .likes:     return "Likes"
        case .posts:     return "Posts"
        }
    }

    /// One-line description for the connect flow's content-type picker.
    var subtitle: String {
        switch self {
        case .bookmarks: return "Tweets you've bookmarked"
        case .likes:     return "Tweets you've liked"
        case .posts:     return "Your own posts"
        }
    }

    /// The path segment under `/2/users/{id}/` this stream reads from.
    var apiPathComponent: String {
        switch self {
        case .bookmarks: return "bookmarks"
        case .likes:     return "liked_tweets"
        case .posts:     return "tweets"
        }
    }

    /// The single OAuth 2.0 scope this stream requires beyond the always-needed
    /// `tweet.read` / `users.read`. Posts need no extra scope (tweet.read covers
    /// the timeline), so it has none.
    var requiredScope: String? {
        switch self {
        case .bookmarks: return "bookmark.read"
        case .likes:     return "like.read"
        case .posts:     return nil
        }
    }

    /// Whether the endpoint honors `since_id` for incremental fetches. The
    /// bookmarks endpoint does not, so that stream stops on a known content ID
    /// instead (see the spec's dedup-by-ID requirement).
    var supportsSinceId: Bool {
        switch self {
        case .bookmarks: return false
        case .likes, .posts: return true
        }
    }
}

// MARK: - Per-source configuration payloads

/// reMarkable source settings: which folder (and optional sub-selection of
/// documents) to pull, plus the read/transcription knobs that used to live
/// directly on `SyncRule`. The folder is the scope a rule targets; each
/// document in it becomes one note.
struct RemarkableSourceConfig: Codable, Equatable, Hashable {
    var folderId: String              // was SyncRule.rmNotebookId
    var folderName: String            // was SyncRule.rmNotebookName
    /// Which documents in the folder to sync. `nil`/empty means the whole folder
    /// (current and future documents); a non-empty set scopes to those file ids.
    var selectedFileIds: [String]? = nil
    var titleStrategy: TitleStrategy
    var titleTemplate: String?
    var pageOrder: PageOrder
    var ocrMode: OcrMode
    var ocrProviderOverride: OcrProviderChoice?
    var savePdfAttachment: Bool
}

/// Safari bookmark source settings: which bookmark folder to pull from. The
/// folder is the scope a rule targets; each bookmark under it becomes one item.
struct SafariSourceConfig: Codable, Equatable, Hashable {
    /// The chosen Safari folder's `WebBookmarkUUID`, or `SafariSourceConfig.allScopeId`
    /// to sync every bookmark.
    var folderId: String
    var folderName: String
    var includeReadingList: Bool = false

    /// Sentinel scope id meaning "every bookmark, all folders" (Reading List excluded).
    static let allScopeId = "__all_safari_bookmarks__"
}

/// Notion source settings: which workspace and database to back up, plus the
/// column that decides the destination folder/notebook. Each row in the database
/// becomes one note; its `Category` value becomes the containing folder. The
/// title column varies per database (usually "Name"), so it's captured here from
/// the schema rather than assumed.
struct NotionSourceConfig: Codable, Equatable, Hashable {
    var workspaceId: String
    var workspaceName: String
    var databaseId: String
    var databaseTitle: String
    /// The database's title property name (e.g. "Name"). Empty falls back to
    /// reading whichever property has type `title`.
    var titleProperty: String = ""
    /// The single-select column whose value becomes the destination folder.
    var categoryProperty: String = NotionSourceConfig.defaultCategoryProperty
    /// The Notion date column that supplies each note's date (its file/creation
    /// date and the `{date}` filename token). Empty means use the page's built-in
    /// `created_time` (which is the migration date for notes imported from
    /// elsewhere); a date property like "Created Date" recovers the original date.
    var dateProperty: String = ""

    static let defaultCategoryProperty = "Category"

    init(workspaceId: String, workspaceName: String, databaseId: String, databaseTitle: String,
         titleProperty: String = "", categoryProperty: String = NotionSourceConfig.defaultCategoryProperty,
         dateProperty: String = "") {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.databaseId = databaseId
        self.databaseTitle = databaseTitle
        self.titleProperty = titleProperty
        self.categoryProperty = categoryProperty
        self.dateProperty = dateProperty
    }

    // Tolerant decoder so configs persisted before later fields existed
    // (titleProperty, categoryProperty, dateProperty) still load — a missing key
    // must not drop the whole rules array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        workspaceName = try c.decode(String.self, forKey: .workspaceName)
        databaseId = try c.decode(String.self, forKey: .databaseId)
        databaseTitle = try c.decode(String.self, forKey: .databaseTitle)
        titleProperty = try c.decodeIfPresent(String.self, forKey: .titleProperty) ?? ""
        categoryProperty = try c.decodeIfPresent(String.self, forKey: .categoryProperty) ?? NotionSourceConfig.defaultCategoryProperty
        dateProperty = try c.decodeIfPresent(String.self, forKey: .dateProperty) ?? ""
    }
}

/// X source settings: which connected account and which content stream
/// (bookmarks / likes / posts) this rule pulls. The stream is the scope a rule
/// targets; each tweet in it becomes one item. The account id is the X user id,
/// which is also the keychain token key and the `/2/users/{id}/…` path segment.
struct XSourceConfig: Codable, Equatable, Hashable {
    var accountId: String          // X user id (numeric, as a string)
    var username: String           // @handle, for canonical URLs and labels
    var stream: XStream
}

// MARK: - Polymorphic configuration

/// The source half of a sync, mirroring `DestinationConfiguration`. One case per
/// `SourceKind`. Adding a source means a new case here, a `SourceClient`, and a
/// `SourceRouter` branch — the destination quartet's exact shape.
enum SourceConfiguration: Codable, Equatable, Hashable {
    case remarkable(RemarkableSourceConfig)
    case safari(SafariSourceConfig)
    case notion(NotionSourceConfig)
    case x(XSourceConfig)

    var kind: SourceKind {
        switch self {
        case .remarkable: return .remarkable
        case .safari:     return .safari
        case .notion:     return .notion
        case .x:          return .x
        }
    }

    /// One-line description shown in rule rows, the menu bar popover, and the
    /// activity log (replaces the old `rule.rmNotebookName` reads).
    var summary: String {
        switch self {
        case .remarkable(let config): return config.folderName
        case .safari(let config):     return config.folderName
        case .notion(let config):     return config.databaseTitle
        case .x(let config):          return "\(config.username) · \(config.stream.label)"
        }
    }
}

// MARK: - Scope

/// A targetable container within a source — a reMarkable folder today. Used by
/// the "Choose a Source" picker and the folder/notebook chooser. Generalizes
/// `RmFolder` for source-agnostic UI; `itemCount` is the number of syncable
/// items (documents) inside.
struct SourceScope: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var itemCount: Int
}

//
//  UploadCoordinator.swift
//  SyncBar
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//
//  Drives reMarkable uploads and the UI that reflects them (the bottom progress
//  bar and the top result banner). A single shared instance is read by MainView,
//  NotebookListView's drop targets, and the menu-bar popover path.
//
//  Concurrency note: uploads are NOT locked against SyncCoordinator. A sync only
//  READS the cloud root, so it can't corrupt an upload, and the uploader's 412
//  re-mirror loop already tolerates the generation advancing under it. The only
//  serialization needed is one upload batch at a time, which the `isUploading`
//  guard provides (so there's never more than one root writer).
//

import Foundation
import Combine

/// A transient post-upload result, shown by `UploadBannerView` and auto-dismissed.
struct UploadBanner: Identifiable, Equatable {
    enum Kind { case success, error }
    let id: UUID
    let kind: Kind
    let count: Int

    /// The user-facing copy, pluralized by `count`.
    var message: String {
        switch kind {
        case .success:
            return count == 1 ? "File uploaded successfully" : "\(count) files uploaded successfully"
        case .error:
            return count == 1 ? "Error uploading file" : "Error uploading \(count) files"
        }
    }
}

@MainActor
final class UploadCoordinator: ObservableObject {
    static let shared = UploadCoordinator()

    @Published private(set) var isUploading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var banner: UploadBanner?

    private static let supportedExtensions: Set<String> = ["pdf", "epub"]

    private init() {}

    /// Uploads `urls` into `folderId` (the destination folder UUID, or "" /
    /// `unfiledFolderId` for the root). Unsupported types and directories are
    /// rejected up front. Ignored if a batch is already running.
    func upload(urls: [URL], toFolderId folderId: String) {
        guard !isUploading else { return }

        let supported = urls.filter {
            !$0.hasDirectoryPath && Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        let rejected = urls.count - supported.count
        guard !supported.isEmpty else {
            if rejected > 0 { showBanner(.error, count: rejected) }
            return
        }

        let destination = (folderId == unfiledFolderId) ? "" : folderId
        let total = supported.count
        isUploading = true
        progress = 0

        Task {
            let client = RemarkableClientFactory.make()
            var succeeded = 0
            var failed = rejected   // unsupported files count as failures in the tally
            for (index, url) in supported.enumerated() {
                do {
                    _ = try await client.uploadDocument(fileURL: url, toFolderId: destination) { fraction in
                        Task { @MainActor in
                            self.progress = (Double(index) + fraction) / Double(total)
                        }
                    }
                    succeeded += 1
                } catch {
                    failed += 1
                    Log.remarkable.error("upload failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    Ledger.shared.updateRemarkableHealth(error: error)
                }
            }

            isUploading = false
            progress = 0
            if failed == 0 {
                showBanner(.success, count: succeeded)
            } else {
                showBanner(.error, count: failed)
            }
            Telemetry.capture("remarkable.upload", properties: ["succeeded": succeeded, "failed": failed])
            if succeeded > 0 {
                NotificationCenter.default.post(name: .remarkableUploadFinished, object: nil)
            }
        }
    }

    private func showBanner(_ kind: UploadBanner.Kind, count: Int) {
        let next = UploadBanner(id: UUID(), kind: kind, count: count)
        banner = next
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if banner?.id == next.id { banner = nil }
        }
    }
}

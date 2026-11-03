import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Saves finished downloads to the photo library.
///
/// Asks only for add-only access: the app never needs to see what else is in the library, and
/// the narrower permission is the one people are comfortable granting.
@MainActor
final class MediaLibrary {

    enum SaveError: LocalizedError, Equatable, Sendable {
        case accessDenied
        case accessRestricted
        case fileMissing(String)
        case audioNotSupported(String)
        case unsupportedFile(String)
        case incompatibleVideo(String)
        case failed(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "YTDLP GUI isn't allowed to add to your photo library. Turn it on in Settings › Privacy & Security › Photos › YTDLP GUI."
            case .accessRestricted:
                "Adding to the photo library is restricted on this device, for example by Screen Time."
            case .fileMissing(let name):
                "“\(name)” is no longer in the YTDLP GUI folder, so it can't be saved to Photos."
            case .audioNotSupported(let name):
                "Photos only keeps videos and pictures, so “\(name)” can't be saved there. Use Share or the Files app instead."
            case .unsupportedFile(let name):
                "Photos can't keep “\(name)”. Use Share or the Files app instead."
            case .incompatibleVideo(let name):
                "Photos can't play “\(name)”, so it can't be saved there. Download it as MP4 video instead."
            case .failed(let name, let reason):
                "Photos couldn't save “\(name)”: \(reason)"
            }
        }
    }

    private enum MediaKind {
        case video
        case image
        case audio
    }

    /// Whether Photos can take this file: a video this device can play, or a picture.
    ///
    /// Checking a video reads the file, so this isn't for view bodies: use
    /// `photosCompatibleFiles(among:)` from a task, or `isPhotosMediaType(_:)` to decide whether
    /// to offer saving at all.
    nonisolated static func isPhotosCompatible(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }
        switch kind(of: url) {
        case .video: return UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path(percentEncoded: false))
        case .image: return true
        case .audio, nil: return false
        }
    }

    /// The files Photos can take, worked out off the main actor.
    nonisolated static func photosCompatibleFiles(among files: [URL]) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            files.filter { MediaLibrary.isPhotosCompatible($0) }
        }.value
    }

    /// Whether the file is a video or a picture, judged by its name alone. Cheap enough for a
    /// menu; whether Photos can really take it is checked when saving.
    nonisolated static func isPhotosMediaType(_ url: URL) -> Bool {
        switch kind(of: url) {
        case .video, .image: true
        case .audio, nil: false
        }
    }

    private var importing = Set<URL>()
    private let commitBatch: ([URL]) async throws -> Void

    init(commitBatch: @escaping ([URL]) async throws -> Void = MediaLibrary.commitToPhotos) {
        self.commitBatch = commitBatch
    }

    /// A single Photos transaction either creates every asset or rolls the batch back.
    @discardableResult
    func saveToPhotos(_ files: [URL]) async throws -> Int {
        guard !files.isEmpty else { return 0 }
        let selection = Set(files)
        guard importing.isDisjoint(with: selection) else { throw SaveError.failed(name: "selection", reason: "A save is already in progress.") }
        importing.formUnion(selection)
        defer { importing.subtract(selection) }
        let compatible = await Self.photosCompatibleFiles(among: files)
        guard !compatible.isEmpty else {
            let url = files[0]
            if !FileManager.default.fileExists(atPath: url.path) { throw SaveError.fileMissing(url.lastPathComponent) }
            if Self.kind(of: url) == .video { throw SaveError.incompatibleVideo(url.lastPathComponent) }
            if Self.kind(of: url) == .audio { throw SaveError.audioNotSupported(url.lastPathComponent) }
            throw SaveError.unsupportedFile(url.lastPathComponent)
        }
        // Eligibility was established before offering this action. If a selected file
        // disappeared in the meantime, don't silently commit a partial selection.
        let eligible = Set(compatible)
        if let missing = files.first(where: { !eligible.contains($0) }) {
            throw SaveError.unsupportedFile(missing.lastPathComponent)
        }
        try await commitBatch(compatible)
        return compatible.count
    }

    private static func commitToPhotos(_ files: [URL]) async throws {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: break
        case .restricted: throw SaveError.accessRestricted
        default: throw SaveError.accessDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in files {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    let type: PHAssetResourceType = Self.kind(of: url) == .video ? .video : .photo
                    PHAssetCreationRequest.forAsset().addResource(with: type, fileURL: url, options: options)
                }
            }
        } catch {
            throw SaveError.failed(name: files.first?.lastPathComponent ?? "selection", reason: "No files were saved. " + error.localizedDescription)
        }
    }

    private nonisolated static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}

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

    /// Whether Photos can take this file (a compatible video or an image).
    func canSaveToPhotos(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }
        switch Self.kind(of: url) {
        case .video: return UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path(percentEncoded: false))
        case .image: return true
        case .audio, nil: return false
        }
    }

    /// Asks for add-only access if it hasn't been decided yet. Returns whether saving is allowed.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: true
        case .denied, .restricted, .notDetermined: false
        @unknown default: false
        }
    }

    /// Asks for add-only access if needed, then saves.
    func saveToPhotos(_ url: URL) async throws {
        let name = url.lastPathComponent
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { throw SaveError.fileMissing(name) }

        let resourceType: PHAssetResourceType
        switch Self.kind(of: url) {
        case .video:
            guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path) else {
                throw SaveError.incompatibleVideo(name)
            }
            resourceType = .video
        case .image:
            resourceType = .photo
        case .audio:
            throw SaveError.audioNotSupported(name)
        case nil:
            throw SaveError.unsupportedFile(name)
        }

        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited:
            break
        case .restricted:
            throw SaveError.accessRestricted
        case .denied, .notDetermined:
            throw SaveError.accessDenied
        @unknown default:
            throw SaveError.accessDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: resourceType, fileURL: url, options: options)
            }
        } catch {
            throw SaveError.failed(name: name, reason: error.localizedDescription)
        }
    }

    private static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}

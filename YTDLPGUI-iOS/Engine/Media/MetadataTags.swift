import AVFoundation
import CoreMedia

/// Builds the tags `embed` writes, in the key spaces each container's readers look for.
///
/// iTunes tags (`ilst`) are what the Music and TV apps, Finder, ffmpeg and nearly every tagger
/// read from MP4 and M4A, and AVFoundation maps the main ones to its common keys. MOV files get
/// the QuickTime metadata keys (`mdta`) as well, which is what Photos and QuickTime read there.
struct MetadataTags {
    let fileType: AVFileType

    /// The tags for `metadata`, one item per key and key space.
    func items(for metadata: MediaMetadata) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let comment = metadata.comment.nonEmpty ?? metadata.webpageURL.nonEmpty
        let date = metadata.date.nonEmpty.map(Self.normalizedDate)

        items += text(.iTunesMetadataSongName, metadata.title)
        items += text(.iTunesMetadataArtist, metadata.artist)
        items += text(.iTunesMetadataAlbum, metadata.album)
        items += text(.iTunesMetadataAlbumArtist, metadata.albumArtist)
        items += text(.iTunesMetadataReleaseDate, date)
        items += text(.iTunesMetadataUserComment, comment)
        items += text(.iTunesMetadataUserGenre, metadata.genre)
        // `desc` is the description atom iTunes and ffmpeg use; AVFoundation's own
        // `©des` is the one it maps to the common description key. Both are written.
        items += text(Self.iTunesDescription, metadata.description)
        items += text(.iTunesMetadataDescription, metadata.description)
        items += text(Self.iTunesPodcastURL, metadata.webpageURL)
        if let trackNumber = metadata.track.flatMap(Self.trackNumberData) {
            items.append(Self.item(.iTunesMetadataTrackNumber, value: trackNumber as NSData, dataType: kCMMetadataBaseDataType_RawData))
        }

        if fileType == .mov {
            items += text(.quickTimeMetadataTitle, metadata.title)
            items += text(.quickTimeMetadataArtist, metadata.artist)
            items += text(.quickTimeMetadataAlbum, metadata.album)
            items += text(.quickTimeMetadataCreationDate, date)
            items += text(.quickTimeMetadataComment, comment)
            items += text(.quickTimeMetadataDescription, metadata.description)
            items += text(.quickTimeMetadataGenre, metadata.genre)
        }
        return items
    }

    /// Cover art items for JPEG or PNG `data`.
    func artworkItems(_ data: Data, format: ImageFormat) -> [AVMetadataItem] {
        let dataType = format == .png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG
        var items = [Self.item(.iTunesMetadataCoverArt, value: data as NSData, dataType: dataType)]
        if fileType == .mov {
            items.append(Self.item(.quickTimeMetadataArtwork, value: data as NSData, dataType: dataType))
        }
        return items
    }

    /// The file's existing tags with `replacements` laid over them.
    ///
    /// Only the key spaces this type writes are carried over. Everything else is either derived
    /// again by AVAssetWriter from the iTunes tags (the 3GPP `udta` copies, the gapless-playback
    /// `iTunSMPB` record) or would contradict the new values, as a stale title in another key
    /// space would.
    func merged(existing: [AVMetadataItem], replacements: [AVMetadataItem]) -> [AVMetadataItem] {
        var keySpaces: Set<AVMetadataKeySpace> = [.iTunes]
        if fileType == .mov {
            keySpaces.insert(.quickTimeMetadata)
        }
        let replaced = Set(replacements.compactMap(\.identifier))
        let kept = existing.filter { item in
            guard let keySpace = item.keySpace, keySpaces.contains(keySpace),
                  let identifier = item.identifier
            else { return false }
            return !replaced.contains(identifier)
        }
        return kept + replacements
    }

    // MARK: - Values

    /// yt-dlp dates are `YYYYMMDD`; Apple's apps read the year from ISO 8601.
    static func normalizedDate(_ date: String) -> String {
        let digits = date.trimmingCharacters(in: .whitespaces)
        guard digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return digits }
        let year = digits.prefix(4)
        let month = digits.dropFirst(4).prefix(2)
        let day = digits.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    /// The binary `trkn` value for "3" or "3/12": two reserved bytes, the track and the total
    /// as big-endian 16-bit numbers, and two more reserved bytes.
    static func trackNumberData(_ track: String) -> Data? {
        let parts = track.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let number = UInt16(first), number > 0 else { return nil }
        let total = parts.count > 1 ? UInt16(parts[1]) ?? 0 : 0
        var data = Data([0, 0])
        withUnsafeBytes(of: number.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: total.bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0, 0])
        return data
    }

    // MARK: - Private

    private static let iTunesDescription = AVMetadataItem.identifier(forKey: "desc", keySpace: .iTunes)
    private static let iTunesPodcastURL = AVMetadataItem.identifier(forKey: "purl", keySpace: .iTunes)

    private func text(_ identifier: AVMetadataIdentifier?, _ value: String?) -> [AVMetadataItem] {
        guard let identifier, let value = value.nonEmpty else { return [] }
        return [Self.item(identifier, value: value as NSString, dataType: kCMMetadataBaseDataType_UTF8)]
    }

    private static func item(_ identifier: AVMetadataIdentifier, value: any NSCopying & NSObjectProtocol, dataType: CFString) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.dataType = dataType as String
        return item
    }
}

private extension Optional where Wrapped == String {
    /// The string with its NULs removed (they can't be stored), or nil if nothing is left.
    var nonEmpty: String? {
        guard let cleaned = self?.replacingOccurrences(of: "\0", with: ""),
              !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return cleaned
    }
}

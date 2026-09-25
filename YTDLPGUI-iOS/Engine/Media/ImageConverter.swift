import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts thumbnails with ImageIO, which decodes WebP, HEIC, AVIF, GIF and the usual formats.
enum ImageConverter {

    /// JPEG quality for converted thumbnails: visually lossless at a fraction of PNG's size.
    static let jpegQuality = 0.9

    static func convert(input: URL, output: URL, format: ImageFormat) async throws {
        let data = try encodedImage(at: input, as: format)
        try await MediaFiles.writeAtomically(to: output) { staging in
            do {
                try data.write(to: staging)
            } catch {
                throw MediaProcessingError.failed(
                    "Couldn't save \(MediaFiles.quotedName(output)): \(MediaErrorText.describe(error))"
                )
            }
        }
    }

    /// The image at `url` encoded as `format`.
    ///
    /// The EXIF orientation is applied to the pixels rather than copied as a tag, because cover
    /// art embedded in a media file is shown as stored — nothing reads a rotation tag there.
    static func encodedImage(at url: URL, as format: ImageFormat) throws -> Data {
        try MediaFiles.requireFile(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              var image = uprightImage(from: source)
        else {
            throw MediaProcessingError.unsupported("\(MediaFiles.quotedName(url)) isn't an image iOS can read.")
        }
        if format == .jpg, image.hasAlpha, let opaque = flattened(image) {
            image = opaque
        }

        let type = format == .png ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw MediaProcessingError.failed("iOS couldn't create a \(format.rawValue.uppercased()) image.")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaProcessingError.failed(
                "iOS couldn't convert \(MediaFiles.quotedName(url)) to \(format.rawValue.uppercased())."
            )
        }
        return data as Data
    }

    /// The format of encoded image `data`, if it is one cover art can hold as is.
    static func coverArtFormat(of data: Data) -> ImageFormat? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpg }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        return nil
    }

    // MARK: - Private

    /// The first frame, rotated and mirrored as its orientation tag says.
    private static func uprightImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1 else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // A "thumbnail" as large as the image is ImageIO's way of applying the orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `image` composited onto white, since JPEG has no transparency and would otherwise turn
    /// transparent areas black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

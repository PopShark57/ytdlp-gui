#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  YTDLP GUI
//
//  Draws the application icon and writes every asset the project needs:
//
//    • YTDLPGUI/Assets.xcassets/AppIcon.appiconset/*.png  (all macOS sizes)
//    • YTDLPGUI/Assets.xcassets/AppIcon.appiconset/Contents.json
//    • Icon/AppIcon.svg                                    (vector master)
//
//  The artwork is defined once, as a list of primitives in a 1024×1024 top-left-origin
//  coordinate space, and rendered twice — through Core Graphics for the PNGs and as SVG
//  markup for the vector master. Keeping one definition is what stops the two from drifting.
//
//  Usage, from the repository root:
//      swift Tools/GenerateAppIcon.swift
//
//  Requires only a Swift toolchain; there are no third-party dependencies.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry primitives

struct Point {
    var x: Double
    var y: Double

    static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }

    /// Moves `distance` from this point toward `other`.
    func moved(toward other: Point, by distance: Double) -> Point {
        let dx = other.x - x
        let dy = other.y - y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return self }
        let ratio = min(distance, length) / length
        return Point(x: x + dx * ratio, y: y + dy * ratio)
    }
}

struct Rectangle {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// One segment of a path. Only these three are needed, and both renderers support all of them
/// natively, so no approximation is involved on either side.
enum PathCommand {
    case move(Point)
    case line(Point)
    case quadratic(control: Point, to: Point)
    case close
}

struct Outline {
    var commands: [PathCommand]

    /// A rectangle with uniformly rounded corners.
    static func roundedRectangle(_ rect: Rectangle, radius: Double) -> Outline {
        let limit = min(rect.width, rect.height) / 2
        let r = min(radius, limit)
        let corners = [
            Point(x: rect.x, y: rect.y),
            Point(x: rect.maxX, y: rect.y),
            Point(x: rect.maxX, y: rect.maxY),
            Point(x: rect.x, y: rect.maxY),
        ]
        return roundedPolygon(corners, radius: r)
    }

    /// A closed polygon whose corners are rounded with quadratic curves.
    ///
    /// Each corner is replaced by two points inset along the adjoining edges, joined by a
    /// quadratic curve whose control point is the original corner. That is exactly how a
    /// rounded corner is drawn in both Core Graphics and SVG, so the two outputs match.
    static func roundedPolygon(_ points: [Point], radius: Double) -> Outline {
        guard points.count >= 3 else { return Outline(commands: []) }

        var commands: [PathCommand] = []
        let count = points.count

        for index in 0..<count {
            let previous = points[(index + count - 1) % count]
            let corner = points[index]
            let next = points[(index + 1) % count]

            let entry = corner.moved(toward: previous, by: radius)
            let exit = corner.moved(toward: next, by: radius)

            if index == 0 {
                commands.append(.move(entry))
            } else {
                commands.append(.line(entry))
            }
            commands.append(.quadratic(control: corner, to: exit))
        }

        commands.append(.close)
        return Outline(commands: commands)
    }
}

// MARK: - Paint

struct RGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    /// Builds a colour from a `0xRRGGBB` literal.
    init(_ hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    var svgHex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

enum Paint {
    case solid(RGBA)
    case linearGradient(start: Point, end: Point, stops: [(offset: Double, color: RGBA)])
}

struct Shadow {
    var offsetY: Double
    var blur: Double
    var color: RGBA
}

struct Element {
    var outline: Outline
    var paint: Paint
    var shadow: Shadow?
    /// Below this pixel size the element is skipped, so fine detail never becomes noise.
    var minimumPixelSize: Int = 0
}

// MARK: - Artwork

/// The icon design.
///
/// A rounded square in the macOS proportions, carrying a bold download arrow over a tray. The
/// arrowhead is a wide, rounded triangle, which doubles as a play symbol turned downwards —
/// the media cue — and film-strip perforations along the sides appear only at the larger sizes
/// where they are legible. No third-party or protected branding is used anywhere.
enum Artwork {

    static let canvas: Double = 1024

    // The Big Sur icon grid: an 824×824 rounded square, optically centred with room for a
    // shadow underneath.
    private static let plate = Rectangle(x: 100, y: 90, width: 824, height: 824)
    private static let plateRadius: Double = 185

    private static let centerX: Double = 512

    static var elements: [Element] {
        var elements: [Element] = []

        // 1. The plate, with its drop shadow.
        elements.append(
            Element(
                outline: .roundedRectangle(plate, radius: plateRadius),
                paint: .linearGradient(
                    start: Point(x: plate.x, y: plate.y),
                    end: Point(x: plate.maxX, y: plate.maxY),
                    stops: [
                        (0.0, RGBA(0x7A5AF8)),
                        (0.52, RGBA(0x4C6FF5)),
                        (1.0, RGBA(0x21C7E6)),
                    ]
                ),
                shadow: Shadow(offsetY: 20, blur: 38, color: RGBA(0x000000, alpha: 0.30))
            )
        )

        // 2. A gloss that follows the plate exactly: white fading out over the top half, so the
        //    plate reads as a lit surface instead of a flat swatch.
        elements.append(
            Element(
                outline: .roundedRectangle(plate, radius: plateRadius),
                paint: .linearGradient(
                    start: Point(x: plate.x, y: plate.y),
                    end: Point(x: plate.x, y: plate.y + 430),
                    stops: [
                        (0.0, RGBA(0xFFFFFF, alpha: 0.20)),
                        (1.0, RGBA(0xFFFFFF, alpha: 0.0)),
                    ]
                ),
                shadow: nil
            )
        )

        // 3. Film perforations, hidden at the sizes where they would just be grit.
        elements.append(contentsOf: perforations())

        // 4. The arrow shaft.
        elements.append(
            Element(
                outline: .roundedRectangle(
                    Rectangle(x: centerX - 55, y: 226, width: 110, height: 250),
                    radius: 55
                ),
                paint: .solid(RGBA(0xFFFFFF)),
                shadow: Shadow(offsetY: 6, blur: 18, color: RGBA(0x101A4A, alpha: 0.22))
            )
        )

        // 5. The arrowhead: a wide rounded triangle pointing down, which doubles as a play
        //    symbol turned through ninety degrees.
        elements.append(
            Element(
                outline: .roundedPolygon(
                    [
                        Point(x: centerX - 178, y: 408),
                        Point(x: centerX + 178, y: 408),
                        Point(x: centerX, y: 644),
                    ],
                    radius: 42
                ),
                paint: .solid(RGBA(0xFFFFFF)),
                shadow: Shadow(offsetY: 6, blur: 18, color: RGBA(0x101A4A, alpha: 0.22))
            )
        )

        // 6. The tray, built from three overlapping rounded bars so every end stays rounded.
        //    The uprights are tall enough to read as a tray rather than as two stray dots.
        let trayTop: Double = 640
        let trayBottom: Double = 786
        let trayLeft = centerX - 220
        let trayRight = centerX + 220
        let barThickness: Double = 56

        for rect in [
            Rectangle(x: trayLeft, y: trayTop, width: barThickness, height: trayBottom - trayTop),
            Rectangle(x: trayRight - barThickness, y: trayTop, width: barThickness, height: trayBottom - trayTop),
            Rectangle(x: trayLeft, y: trayBottom - barThickness, width: trayRight - trayLeft, height: barThickness),
        ] {
            elements.append(
                Element(
                    outline: .roundedRectangle(rect, radius: barThickness / 2),
                    paint: .solid(RGBA(0xFFFFFF, alpha: 0.92)),
                    shadow: nil
                )
            )
        }

        return elements
    }

    private static func perforations() -> [Element] {
        var elements: [Element] = []
        let size: Double = 40
        let radius: Double = 13
        let columns = [plate.x + 52, plate.maxX - 52 - size]
        let firstY: Double = 206
        let spacing: Double = 152

        for column in columns {
            for row in 0..<4 {
                let rect = Rectangle(
                    x: column,
                    y: firstY + Double(row) * spacing,
                    width: size,
                    height: size
                )
                elements.append(
                    Element(
                        outline: .roundedRectangle(rect, radius: radius),
                        paint: .solid(RGBA(0xFFFFFF, alpha: 0.13)),
                        shadow: nil,
                        minimumPixelSize: 128
                    )
                )
            }
        }
        return elements
    }
}

// MARK: - Core Graphics renderer

enum BitmapRenderer {

    /// Renders the artwork at `pixelSize` and returns PNG data.
    static func render(pixelSize: Int) throws -> Data {
        let scale = Double(pixelSize) / Artwork.canvas
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GeneratorError.contextCreationFailed(pixelSize)
        }

        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        // Flip into a top-left origin so the artwork's coordinates read like SVG's.
        context.translateBy(x: 0, y: CGFloat(pixelSize))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

        for element in Artwork.elements where pixelSize >= element.minimumPixelSize {
            draw(element, in: context, colorSpace: colorSpace)
        }

        guard let image = context.makeImage() else {
            throw GeneratorError.imageCreationFailed(pixelSize)
        }
        return try encodePNG(image)
    }

    private static func draw(_ element: Element, in context: CGContext, colorSpace: CGColorSpace) {
        let path = makePath(element.outline)

        context.saveGState()

        if let shadow = element.shadow {
            let color = CGColor(
                colorSpace: colorSpace,
                components: [
                    CGFloat(shadow.color.red),
                    CGFloat(shadow.color.green),
                    CGFloat(shadow.color.blue),
                    CGFloat(shadow.color.alpha),
                ]
            )
            context.setShadow(
                offset: CGSize(width: 0, height: CGFloat(shadow.offsetY)),
                blur: CGFloat(shadow.blur),
                color: color
            )
        }

        switch element.paint {
        case .solid(let color):
            context.setFillColor(
                red: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.alpha)
            )
            context.addPath(path)
            context.fillPath()

        case .linearGradient(let start, let end, let stops):
            // A gradient can't be a fill colour, so the shape becomes a clip and the gradient
            // is drawn through it. The shadow is painted first, from the shape itself.
            if element.shadow != nil {
                context.setFillColor(gray: 0, alpha: 1)
                context.addPath(path)
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            context.addPath(path)
            context.clip()

            let components = stops.flatMap { stop in
                [
                    CGFloat(stop.color.red),
                    CGFloat(stop.color.green),
                    CGFloat(stop.color.blue),
                    CGFloat(stop.color.alpha),
                ]
            }
            let locations = stops.map { CGFloat($0.offset) }
            if let gradient = CGGradient(
                colorSpace: colorSpace,
                colorComponents: components,
                locations: locations,
                count: stops.count
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: start.x, y: start.y),
                    end: CGPoint(x: end.x, y: end.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        }

        context.restoreGState()
    }

    private static func makePath(_ outline: Outline) -> CGPath {
        let path = CGMutablePath()
        for command in outline.commands {
            switch command {
            case .move(let point):
                path.move(to: CGPoint(x: point.x, y: point.y))
            case .line(let point):
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            case .quadratic(let control, let point):
                path.addQuadCurve(
                    to: CGPoint(x: point.x, y: point.y),
                    control: CGPoint(x: control.x, y: control.y)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw GeneratorError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GeneratorError.encodingFailed
        }
        return data as Data
    }
}

// MARK: - SVG renderer

enum SVGRenderer {

    static func render() -> String {
        var body = ""
        var definitions = ""
        var gradientIndex = 0

        for element in Artwork.elements {
            let d = pathData(element.outline)
            var attributes = ""

            switch element.paint {
            case .solid(let color):
                attributes = #"fill="\#(color.svgHex)""#
                if color.alpha < 1 {
                    attributes += #" fill-opacity="\#(trim(color.alpha))""#
                }

            case .linearGradient(let start, let end, let stops):
                let id = "grad\(gradientIndex)"
                gradientIndex += 1
                let stopMarkup = stops.map { stop in
                    var markup = #"      <stop offset="\#(trim(stop.offset))" stop-color="\#(stop.color.svgHex)""#
                    if stop.color.alpha < 1 {
                        markup += #" stop-opacity="\#(trim(stop.color.alpha))""#
                    }
                    return markup + "/>"
                }.joined(separator: "\n")
                definitions += """
                    <linearGradient id="\(id)" gradientUnits="userSpaceOnUse" \
                x1="\(trim(start.x))" y1="\(trim(start.y))" x2="\(trim(end.x))" y2="\(trim(end.y))">
                \(stopMarkup)
                    </linearGradient>

                """
                attributes = #"fill="url(#\#(id))""#
            }

            if element.minimumPixelSize > 0 {
                attributes += #" class="detail""#
            }

            body += "  <path \(attributes) d=\"\(d)\"/>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!--
          YTDLP GUI application icon.
          Generated by Tools/GenerateAppIcon.swift — edit that file, not this one.
        -->
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <title>YTDLP GUI</title>
          <defs>
        \(definitions.isEmpty ? "" : definitions)  </defs>
        \(body)</svg>

        """
    }

    private static func pathData(_ outline: Outline) -> String {
        outline.commands.map { command in
            switch command {
            case .move(let p): "M\(trim(p.x)) \(trim(p.y))"
            case .line(let p): "L\(trim(p.x)) \(trim(p.y))"
            case .quadratic(let c, let p): "Q\(trim(c.x)) \(trim(c.y)) \(trim(p.x)) \(trim(p.y))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
    }
}

// MARK: - Asset catalogue

struct IconVariant {
    var idiom = "mac"
    var size: Int
    var scale: Int

    var pixelSize: Int { size * scale }
    var fileName: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }

    var contentsEntry: [String: String] {
        [
            "idiom": idiom,
            "size": "\(size)x\(size)",
            "scale": "\(scale)x",
            "filename": fileName,
        ]
    }
}

let variants: [IconVariant] = [16, 32, 128, 256, 512].flatMap { size in
    [IconVariant(size: size, scale: 1), IconVariant(size: size, scale: 2)]
}

enum GeneratorError: LocalizedError {
    case contextCreationFailed(Int)
    case imageCreationFailed(Int)
    case encodingFailed
    case badWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed(let size): "Couldn't create a \(size)px drawing context."
        case .imageCreationFailed(let size): "Couldn't produce a \(size)px image."
        case .encodingFailed: "Couldn't encode the PNG data."
        case .badWorkingDirectory(let path):
            "Run this from the repository root. Expected to find YTDLPGUI/Assets.xcassets at \(path)."
        }
    }
}

// MARK: - Entry point

func generate() throws {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    let assetCatalog = root.appending(path: "YTDLPGUI/Assets.xcassets")

    guard fileManager.fileExists(atPath: assetCatalog.path) else {
        throw GeneratorError.badWorkingDirectory(assetCatalog.path)
    }

    let iconSet = assetCatalog.appending(path: "AppIcon.appiconset")
    try fileManager.createDirectory(at: iconSet, withIntermediateDirectories: true)

    // One PNG per distinct pixel size; several variants can share a file name only if their
    // pixel sizes agree, so each is written under its own name.
    print("Rendering \(variants.count) icon images…")
    for variant in variants {
        let data = try BitmapRenderer.render(pixelSize: variant.pixelSize)
        let url = iconSet.appending(path: variant.fileName)
        try data.write(to: url, options: .atomic)
        print("  \(variant.fileName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(variant.pixelSize)×\(variant.pixelSize)px  \(data.count / 1024) KB")
    }

    let contents: [String: Any] = [
        "images": variants.map(\.contentsEntry),
        "info": ["version": 1, "author": "GenerateAppIcon.swift"],
    ]
    let contentsData = try JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys]
    )
    try contentsData.write(to: iconSet.appending(path: "Contents.json"), options: .atomic)
    print("Wrote Contents.json")

    let iconDirectory = root.appending(path: "Icon")
    try fileManager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
    let svg = SVGRenderer.render()
    try svg.write(to: iconDirectory.appending(path: "AppIcon.svg"), atomically: true, encoding: .utf8)
    print("Wrote Icon/AppIcon.svg")
}

do {
    try generate()
    print("Done.")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

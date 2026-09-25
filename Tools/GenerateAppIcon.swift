#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  YTDLP GUI
//
//  Draws the application icons and writes every asset the project needs:
//
//    macOS
//    • YTDLPGUI/Assets.xcassets/AppIcon.appiconset/*.png          (all macOS sizes)
//    • YTDLPGUI/Assets.xcassets/AppIcon.appiconset/Contents.json
//    • Icon/AppIcon.svg                                           (vector master)
//
//    iOS
//    • YTDLPGUI-iOS/Assets.xcassets/AppIcon.appiconset/*.png      (1024px light, dark, tinted)
//    • YTDLPGUI-iOS/Assets.xcassets/AppIcon.appiconset/Contents.json
//    • YTDLPGUI-iOS/Assets.xcassets/AccentColor.colorset/Contents.json
//
//  The motif is defined once, as a list of primitives in a 1024×1024 top-left-origin
//  coordinate space, and composed into two artworks. The macOS icon carries its own rounded
//  plate, margin and drop shadow, because macOS draws icons as supplied. The iOS icon is a
//  full-bleed square, because iOS applies the rounded mask itself; besides the opaque light
//  icon, it comes in the dark and tinted appearances iOS 18 offers on the Home Screen.
//
//  The macOS artwork is rendered twice — through Core Graphics for the PNGs and as SVG markup
//  for the vector master. Keeping one definition is what stops the outputs from drifting.
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

/// The space every artwork is drawn in: a 1024×1024 square with a top-left origin, as in SVG.
enum Canvas {
    static let size: Double = 1024
    static let bounds = Rectangle(x: 0, y: 0, width: size, height: size)
}

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

/// Maps one square onto another, scaling uniformly.
///
/// This is how the iOS icon reuses the macOS motif: rather than restating every coordinate for
/// a second layout, the macOS plate is mapped onto the iOS canvas.
struct SquareMapping {
    var source: Rectangle
    var destination: Rectangle

    func apply(_ point: Point) -> Point {
        let scale = destination.width / source.width
        return Point(
            x: destination.x + (point.x - source.x) * scale,
            y: destination.y + (point.y - source.y) * scale
        )
    }
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

    /// A rectangle with square corners.
    static func rectangle(_ rect: Rectangle) -> Outline {
        Outline(commands: [
            .move(Point(x: rect.x, y: rect.y)),
            .line(Point(x: rect.maxX, y: rect.y)),
            .line(Point(x: rect.maxX, y: rect.maxY)),
            .line(Point(x: rect.x, y: rect.maxY)),
            .close,
        ])
    }

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

    func mapped(by mapping: SquareMapping) -> Outline {
        Outline(commands: commands.map { command in
            switch command {
            case .move(let point): .move(mapping.apply(point))
            case .line(let point): .line(mapping.apply(point))
            case .quadratic(let control, let point):
                .quadratic(control: mapping.apply(control), to: mapping.apply(point))
            case .close: .close
            }
        })
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

    /// The components in the form Xcode writes into a colour set.
    var assetCatalogComponents: [String: String] {
        func byte(_ value: Double) -> String { String(format: "0x%02X", Int((value * 255).rounded())) }
        return [
            "red": byte(red),
            "green": byte(green),
            "blue": byte(blue),
            "alpha": String(format: "%.3f", alpha),
        ]
    }
}

typealias GradientStops = [(offset: Double, color: RGBA)]

enum Paint {
    case solid(RGBA)
    case linearGradient(start: Point, end: Point, stops: GradientStops)
}

/// A drop shadow, handed to Core Graphics as is.
///
/// Core Graphics applies shadows in the context's base space and ignores the transform, so
/// both values are in output pixels and a positive `offsetY` moves the shadow *up*. The iOS
/// artwork is only ever rendered at 1024px, where pixels and artwork units coincide.
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

// MARK: - Palette

enum Palette {
    static let violet = RGBA(0x7A5AF8)
    static let indigo = RGBA(0x4C6FF5)
    static let cyan = RGBA(0x21C7E6)

    /// The plate's diagonal sweep, shared by both platforms so they read as one app.
    static let plate: GradientStops = [
        (0.0, violet),
        (0.52, indigo),
        (1.0, cyan),
    ]

    /// The same sweep lifted in lightness, for the glyph of the dark iOS icon. The plate colours
    /// themselves sit too close to the dark Home Screen background to read as luminous.
    static let luminous: GradientStops = [
        (0.0, RGBA(0xA48FFF)),
        (0.52, RGBA(0x7A95FF)),
        (1.0, RGBA(0x5CE1F5)),
    ]

    /// The iOS accent colour: the plate's indigo, darkened for light mode and lightened for dark
    /// mode so tinted text and controls keep at least 4.5:1 contrast where they sit — 4.9:1 on
    /// white, and 5.6:1 on black or 4.5:1 on a dark grouped-list cell. The plate's indigo
    /// itself manages 4.3:1 on white, and system blue 4.0:1.
    static let accentLight = RGBA(0x3E64F4)
    static let accentDark = RGBA(0x5B7BF6)
}

// MARK: - Motif

/// The shapes both icons share, laid out for macOS: an 824-point plate on the canvas.
///
/// A bold download arrow over a tray. The arrowhead is a wide, rounded triangle, which doubles
/// as a play symbol turned downwards — the media cue — and film-strip perforations run down the
/// sides of the plate. No third-party or protected branding is used anywhere.
enum Motif {

    // The Big Sur icon grid: an 824×824 rounded square, optically centred with room for a
    // shadow underneath.
    static let plate = Rectangle(x: 100, y: 90, width: 824, height: 824)
    static let plateRadius: Double = 185

    /// How far down the plate the gloss fades out.
    static let glossDepth: Double = 430

    private static let centerX: Double = 512
    private static let shaftTop: Double = 226

    // The tray's uprights are tall enough to read as a tray rather than as two stray dots.
    private static let trayTop: Double = 640
    private static let trayBottom: Double = 786
    private static let trayLeft = centerX - 220
    private static let trayRight = centerX + 220
    private static let barThickness: Double = 56

    /// The box the arrow and tray fill, for paint that should run across all of them.
    static var glyphBounds: Rectangle {
        Rectangle(x: trayLeft, y: shaftTop, width: trayRight - trayLeft, height: trayBottom - shaftTop)
    }

    static var shaft: Outline {
        .roundedRectangle(
            Rectangle(x: centerX - 55, y: shaftTop, width: 110, height: 250),
            radius: 55
        )
    }

    /// A wide rounded triangle pointing down, which doubles as a play symbol turned through
    /// ninety degrees.
    static var arrowhead: Outline {
        .roundedPolygon(
            [
                Point(x: centerX - 178, y: 408),
                Point(x: centerX + 178, y: 408),
                Point(x: centerX, y: 644),
            ],
            radius: 42
        )
    }

    /// The tray as three overlapping rounded bars, so every end stays rounded.
    ///
    /// The macOS artwork is built this way and its committed PNGs depend on it. Under a
    /// translucent fill the overlaps come out slightly brighter; `trayOutline` avoids that.
    static var trayBars: [Outline] {
        [
            Rectangle(x: trayLeft, y: trayTop, width: barThickness, height: trayBottom - trayTop),
            Rectangle(x: trayRight - barThickness, y: trayTop, width: barThickness, height: trayBottom - trayTop),
            Rectangle(x: trayLeft, y: trayBottom - barThickness, width: trayRight - trayLeft, height: barThickness),
        ].map { .roundedRectangle($0, radius: barThickness / 2) }
    }

    /// The same tray as a single U-shaped outline, so a translucent fill covers it evenly. The
    /// ends match the bars exactly; the inside corners gain a fillet.
    static var trayOutline: Outline {
        .roundedPolygon(
            [
                Point(x: trayLeft, y: trayTop),
                Point(x: trayLeft + barThickness, y: trayTop),
                Point(x: trayLeft + barThickness, y: trayBottom - barThickness),
                Point(x: trayRight - barThickness, y: trayBottom - barThickness),
                Point(x: trayRight - barThickness, y: trayTop),
                Point(x: trayRight, y: trayTop),
                Point(x: trayRight, y: trayBottom),
                Point(x: trayLeft, y: trayBottom),
            ],
            radius: barThickness / 2
        )
    }

    /// Film perforations down both sides of the plate, left column first.
    static var perforations: [Outline] {
        var outlines: [Outline] = []
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
                outlines.append(.roundedRectangle(rect, radius: radius))
            }
        }
        return outlines
    }
}

// MARK: - macOS artwork

/// The macOS icon: the motif on a rounded plate in the macOS proportions, with a drop shadow,
/// since macOS draws an icon exactly as supplied.
enum MacArtwork {

    static var elements: [Element] {
        var elements: [Element] = []
        let plate = Motif.plate

        // 1. The plate, with its drop shadow.
        elements.append(
            Element(
                outline: .roundedRectangle(plate, radius: Motif.plateRadius),
                paint: .linearGradient(
                    start: Point(x: plate.x, y: plate.y),
                    end: Point(x: plate.maxX, y: plate.maxY),
                    stops: Palette.plate
                ),
                shadow: Shadow(offsetY: 20, blur: 38, color: RGBA(0x000000, alpha: 0.30))
            )
        )

        // 2. A gloss that follows the plate exactly: white fading out over the top half, so the
        //    plate reads as a lit surface instead of a flat swatch.
        elements.append(
            Element(
                outline: .roundedRectangle(plate, radius: Motif.plateRadius),
                paint: .linearGradient(
                    start: Point(x: plate.x, y: plate.y),
                    end: Point(x: plate.x, y: plate.y + Motif.glossDepth),
                    stops: [
                        (0.0, RGBA(0xFFFFFF, alpha: 0.20)),
                        (1.0, RGBA(0xFFFFFF, alpha: 0.0)),
                    ]
                ),
                shadow: nil
            )
        )

        // 3. Film perforations, hidden at the sizes where they would just be grit.
        elements.append(contentsOf: Motif.perforations.map { outline in
            Element(
                outline: outline,
                paint: .solid(RGBA(0xFFFFFF, alpha: 0.13)),
                shadow: nil,
                minimumPixelSize: 128
            )
        })

        // 4. The arrow: shaft, then head.
        for outline in [Motif.shaft, Motif.arrowhead] {
            elements.append(
                Element(
                    outline: outline,
                    paint: .solid(RGBA(0xFFFFFF)),
                    shadow: Shadow(offsetY: 6, blur: 18, color: RGBA(0x101A4A, alpha: 0.22))
                )
            )
        }

        // 5. The tray.
        elements.append(contentsOf: Motif.trayBars.map { outline in
            Element(outline: outline, paint: .solid(RGBA(0xFFFFFF, alpha: 0.92)), shadow: nil)
        })

        return elements
    }
}

// MARK: - iOS artwork

/// The Home Screen appearances iOS 18 lets people choose between.
enum IOSAppearance: CaseIterable {
    case light
    case dark
    case tinted

    var fileName: String {
        switch self {
        case .light: "icon_1024x1024.png"
        case .dark: "icon_1024x1024_dark.png"
        case .tinted: "icon_1024x1024_tinted.png"
        }
    }

    /// The App Store rejects a primary iOS icon that has an alpha channel at all, even a fully
    /// opaque one. Only the dark icon may be transparent: the system fills in its own dark
    /// background behind it. The tinted icon carries nothing but brightness, so it is stored
    /// as a single grey channel.
    var pixelFormat: PixelFormat {
        switch self {
        case .light: .rgb
        case .dark: .rgba
        case .tinted: .gray
        }
    }

    var contentsEntry: [String: Any] {
        var entry: [String: Any] = [
            "filename": fileName,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        ]
        switch self {
        case .light:
            break
        case .dark:
            entry["appearances"] = [["appearance": "luminosity", "value": "dark"]]
        case .tinted:
            entry["appearances"] = [["appearance": "luminosity", "value": "tinted"]]
        }
        return entry
    }
}

/// The iOS icon: a full-bleed square with no corners or shadow of its own, since iOS applies
/// the mask. Only a single 1024px image is supplied; the system scales it for every context.
///
/// The macOS plate is mapped onto the whole canvas. The iOS mask rounds its corners by almost
/// exactly the plate's ratio (22.4% against 22.5%), so a masked iOS icon looks like the Mac
/// plate, and the arrow and tray, at 68% of the height, sit well inside the central 80%.
enum IOSArtwork {

    static let pixelSize = 1024

    private static let placement = SquareMapping(source: Motif.plate, destination: Canvas.bounds)

    static func elements(for appearance: IOSAppearance) -> [Element] {
        switch appearance {
        case .light: lightElements
        case .dark: darkElements
        case .tinted: tintedElements
        }
    }

    // Negative, so the shadow falls below the glyph, as light from above would cast it (see
    // `Shadow`).
    private static let glyphShadow = Shadow(offsetY: -8, blur: 22, color: RGBA(0x101A4A, alpha: 0.22))

    private static var lightElements: [Element] {
        var elements: [Element] = []

        elements.append(
            Element(
                outline: .rectangle(Canvas.bounds),
                paint: .linearGradient(
                    start: placement.apply(Point(x: Motif.plate.x, y: Motif.plate.y)),
                    end: placement.apply(Point(x: Motif.plate.maxX, y: Motif.plate.maxY)),
                    stops: Palette.plate
                ),
                shadow: nil
            )
        )

        elements.append(
            Element(
                outline: .rectangle(Canvas.bounds),
                paint: .linearGradient(
                    start: placement.apply(Point(x: Motif.plate.x, y: Motif.plate.y)),
                    end: placement.apply(Point(x: Motif.plate.x, y: Motif.plate.y + Motif.glossDepth)),
                    stops: [
                        (0.0, RGBA(0xFFFFFF, alpha: 0.20)),
                        (1.0, RGBA(0xFFFFFF, alpha: 0.0)),
                    ]
                ),
                shadow: nil
            )
        )

        elements.append(contentsOf: perforations(RGBA(0xFFFFFF, alpha: 0.13)))

        for outline in [Motif.shaft, Motif.arrowhead] {
            elements.append(
                Element(outline: outline.mapped(by: placement), paint: .solid(RGBA(0xFFFFFF)), shadow: glyphShadow)
            )
        }

        elements.append(
            Element(
                outline: Motif.trayOutline.mapped(by: placement),
                paint: .solid(RGBA(0xFFFFFF, alpha: 0.92)),
                shadow: nil
            )
        )
        return elements
    }

    /// The glyph in the brand colours, lifted to glow against the system's dark background,
    /// which shows through the transparent canvas. There's no plate to lift the glyph off, so
    /// it has no shadow, and the tray is drawn solid.
    private static var darkElements: [Element] {
        let bounds = Motif.glyphBounds
        let paint = Paint.linearGradient(
            start: placement.apply(Point(x: bounds.x, y: bounds.y)),
            end: placement.apply(Point(x: bounds.maxX, y: bounds.maxY)),
            stops: Palette.luminous
        )
        return perforations(RGBA(0xFFFFFF, alpha: 0.16))
            + glyph.map { Element(outline: $0, paint: paint, shadow: nil) }
    }

    /// A grayscale rendition for the system to colour with the person's tint. Brightness sets
    /// how strongly each part takes the tint, so the glyph is white on black and the
    /// perforations a faint grey.
    private static var tintedElements: [Element] {
        [Element(outline: .rectangle(Canvas.bounds), paint: .solid(RGBA(0x000000)), shadow: nil)]
            + perforations(RGBA(0xFFFFFF, alpha: 0.2))
            + glyph.map { Element(outline: $0, paint: .solid(RGBA(0xFFFFFF)), shadow: nil) }
    }

    private static var glyph: [Outline] {
        [Motif.shaft, Motif.arrowhead, Motif.trayOutline].map { $0.mapped(by: placement) }
    }

    /// The iOS icon is only ever rendered at 1024px, so the perforations are always shown.
    private static func perforations(_ color: RGBA) -> [Element] {
        Motif.perforations.map { outline in
            Element(outline: outline.mapped(by: placement), paint: .solid(color), shadow: nil)
        }
    }
}

// MARK: - Core Graphics renderer

/// How a rendered bitmap stores its pixels.
enum PixelFormat {
    /// sRGB with premultiplied alpha.
    case rgba
    /// sRGB with no alpha channel at all.
    case rgb
    /// A single grey channel with no alpha.
    case gray

    var colorSpace: CGColorSpace? {
        switch self {
        case .rgba, .rgb: CGColorSpace(name: CGColorSpace.sRGB)
        case .gray: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        }
    }

    var bitmapInfo: UInt32 {
        switch self {
        case .rgba: CGImageAlphaInfo.premultipliedLast.rawValue
        case .rgb: CGImageAlphaInfo.noneSkipLast.rawValue
        case .gray: CGImageAlphaInfo.none.rawValue
        }
    }
}

enum BitmapRenderer {

    /// Renders `elements`, drawn on the canvas, at `pixelSize` and returns PNG data.
    static func render(_ elements: [Element], pixelSize: Int, format: PixelFormat = .rgba) throws -> Data {
        let scale = Double(pixelSize) / Canvas.size
        // Colours are always specified in sRGB, whatever the bitmap stores.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapSpace = format.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: bitmapSpace,
                  bitmapInfo: format.bitmapInfo
              )
        else {
            throw GeneratorError.contextCreationFailed(pixelSize)
        }

        context.interpolationQuality = .high
        context.setShouldAntialias(true)

        // Flip into a top-left origin so the artwork's coordinates read like SVG's.
        context.translateBy(x: 0, y: CGFloat(pixelSize))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

        for element in elements where pixelSize >= element.minimumPixelSize {
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

    static func render(_ elements: [Element]) -> String {
        var body = ""
        var definitions = ""
        var gradientIndex = 0

        for element in elements {
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

// MARK: - Asset catalogues

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

let macVariants: [IconVariant] = [16, 32, 128, 256, 512].flatMap { size in
    [IconVariant(size: size, scale: 1), IconVariant(size: size, scale: 2)]
}

enum AssetCatalog {

    /// Credits the generator, so nobody edits these files in Xcode expecting the change to stick.
    static var info: [String: Any] { ["version": 1, "author": "GenerateAppIcon.swift"] }

    /// The iOS accent colour set, with its dark-mode variant.
    static var accentColorContents: [String: Any] {
        [
            "colors": [
                [
                    "color": ["color-space": "srgb", "components": Palette.accentLight.assetCatalogComponents],
                    "idiom": "universal",
                ],
                [
                    "appearances": [["appearance": "luminosity", "value": "dark"]],
                    "color": ["color-space": "srgb", "components": Palette.accentDark.assetCatalogComponents],
                    "idiom": "universal",
                ],
            ],
            "info": info,
        ]
    }

    /// Returns the catalogue at `path`, which must already exist: a missing one means the
    /// script is running from the wrong directory, not that a catalogue should be invented.
    static func locate(_ path: String, in root: URL) throws -> URL {
        let catalog = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: catalog.path) else {
            throw GeneratorError.missingAssetCatalog(catalog.path)
        }
        return catalog
    }

    static func writeContents(_ contents: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appending(path: "Contents.json"), options: .atomic)
    }
}

enum GeneratorError: LocalizedError {
    case contextCreationFailed(Int)
    case imageCreationFailed(Int)
    case encodingFailed
    case missingAssetCatalog(String)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed(let size): "Couldn't create a \(size)px drawing context."
        case .imageCreationFailed(let size): "Couldn't produce a \(size)px image."
        case .encodingFailed: "Couldn't encode the PNG data."
        case .missingAssetCatalog(let path):
            "Run this from the repository root. Expected to find an asset catalogue at \(path)."
        }
    }
}

// MARK: - Entry point

func describe(_ fileName: String, pixelSize: Int, bytes: Int) -> String {
    "  \(fileName.padding(toLength: 26, withPad: " ", startingAt: 0)) \(pixelSize)×\(pixelSize)px  \(bytes / 1024) KB"
}

func generateMac(root: URL) throws {
    let fileManager = FileManager.default
    let iconSet = try AssetCatalog.locate("YTDLPGUI/Assets.xcassets", in: root).appending(path: "AppIcon.appiconset")
    try fileManager.createDirectory(at: iconSet, withIntermediateDirectories: true)

    // One PNG per distinct pixel size; several variants can share a file name only if their
    // pixel sizes agree, so each is written under its own name.
    print("Rendering \(macVariants.count) macOS icon images…")
    let elements = MacArtwork.elements
    for variant in macVariants {
        let data = try BitmapRenderer.render(elements, pixelSize: variant.pixelSize)
        try data.write(to: iconSet.appending(path: variant.fileName), options: .atomic)
        print(describe(variant.fileName, pixelSize: variant.pixelSize, bytes: data.count))
    }

    try AssetCatalog.writeContents(["images": macVariants.map(\.contentsEntry), "info": AssetCatalog.info], to: iconSet)
    print("Wrote Contents.json")

    let iconDirectory = root.appending(path: "Icon")
    try fileManager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
    let svg = SVGRenderer.render(elements)
    try svg.write(to: iconDirectory.appending(path: "AppIcon.svg"), atomically: true, encoding: .utf8)
    print("Wrote Icon/AppIcon.svg")
}

func generateIOS(root: URL) throws {
    let fileManager = FileManager.default
    let catalog = try AssetCatalog.locate("YTDLPGUI-iOS/Assets.xcassets", in: root)
    let iconSet = catalog.appending(path: "AppIcon.appiconset")
    try fileManager.createDirectory(at: iconSet, withIntermediateDirectories: true)

    print("Rendering \(IOSAppearance.allCases.count) iOS icon images…")
    for appearance in IOSAppearance.allCases {
        let data = try BitmapRenderer.render(
            IOSArtwork.elements(for: appearance),
            pixelSize: IOSArtwork.pixelSize,
            format: appearance.pixelFormat
        )
        try data.write(to: iconSet.appending(path: appearance.fileName), options: .atomic)
        print(describe(appearance.fileName, pixelSize: IOSArtwork.pixelSize, bytes: data.count))
    }

    try AssetCatalog.writeContents(
        ["images": IOSAppearance.allCases.map(\.contentsEntry), "info": AssetCatalog.info],
        to: iconSet
    )
    print("Wrote Contents.json")

    let accentSet = catalog.appending(path: "AccentColor.colorset")
    try fileManager.createDirectory(at: accentSet, withIntermediateDirectories: true)
    try AssetCatalog.writeContents(AssetCatalog.accentColorContents, to: accentSet)
    print("Wrote AccentColor.colorset")
}

do {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    try generateMac(root: root)
    try generateIOS(root: root)
    print("Done.")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

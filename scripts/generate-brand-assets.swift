// generate-brand-assets.swift
//
// Draws heySona's brand assets from one set of shapes, so the app icon,
// logo, and SVG mark always match:
//   - leanring-buddy/Assets.xcassets/AppIcon.appiconset/*.png  (app icon, all sizes)
//   - branding/heysona-mark.svg                                (the mark, scalable)
//   - branding/heysona-logo-light.png / -dark.png              (mark + wordmark)
//
// The mark: heySona's blue cursor triangle as a speaker, with sound waves
// coming off its flat side ("the cursor that talks"), on a deep indigo
// macOS-style rounded square.
//
// Run from the repository root:
//   swift scripts/generate-brand-assets.swift

import AppKit
import Foundation

// MARK: - Geometry (1024 x 1024 canvas, top-left origin)

struct BrandGeometry {
    static let canvasSize: CGFloat = 1024

    /// The rounded-square icon body, inset like Apple's macOS icon grid.
    static let iconBodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let iconBodyCornerRadius: CGFloat = 186

    /// The mark is laid out pointing left (flat side facing right), then the
    /// whole group is tilted by `markTiltInDegrees` so the triangle points
    /// up-left like a mouse pointer and the waves flow down-right.
    /// A narrow wedge like a mouse pointer: sharp tip on the left, short
    /// flat side on the right (about a 48° tip angle).
    static let pointerTip = CGPoint(x: 230, y: 512)
    static let pointerFlatSideTop = CGPoint(x: 560, y: 362)
    static let pointerFlatSideBottom = CGPoint(x: 560, y: 662)
    static let pointerTipCornerRadius: CGFloat = 26
    static let pointerFlatSideCornerRadius: CGFloat = 40

    static var triangleCentroid: CGPoint {
        CGPoint(
            x: (pointerTip.x + pointerFlatSideTop.x + pointerFlatSideBottom.x) / 3,
            y: (pointerTip.y + pointerFlatSideTop.y + pointerFlatSideBottom.y) / 3
        )
    }

    /// Sound waves are arcs centered just inside the triangle's flat side,
    /// starting far enough out to leave a clear gap from the triangle.
    static let soundWaveArcCenter = CGPoint(x: 430, y: 512)
    static let soundWaveArcHalfAngleInDegrees: CGFloat = 36

    static let markTiltInDegrees: CGFloat = 40
    /// Middle of the untilted group (triangle tip to outermost wave).
    /// Set right of the geometric middle because the waves carry most of the
    /// visual weight; this keeps the tilted mark balanced in the body.
    static let untiltedMarkGroupCenter = CGPoint(x: 585, y: 512)
    /// Shrinks the group a little so the tilted mark sits well inside the body.
    static let markScale: CGFloat = 0.92

    /// Moves the group's middle to the canvas center, tilts, and scales it.
    static var markTransform: CGAffineTransform {
        let tiltInRadians = markTiltInDegrees * .pi / 180
        return CGAffineTransform(translationX: canvasSize / 2, y: canvasSize / 2)
            .rotated(by: tiltInRadians)
            .scaledBy(x: markScale, y: markScale)
            .translatedBy(x: -untiltedMarkGroupCenter.x, y: -untiltedMarkGroupCenter.y)
    }

    struct SoundWave {
        let radius: CGFloat
        let strokeWidth: CGFloat
        let opacity: CGFloat
    }

    /// Full detail for large icons and the logo.
    static let detailedSoundWaves = [
        SoundWave(radius: 225, strokeWidth: 48, opacity: 1.0),
        SoundWave(radius: 305, strokeWidth: 48, opacity: 0.72),
        SoundWave(radius: 385, strokeWidth: 48, opacity: 0.45)
    ]

    /// Fewer, thicker waves so 16-64 px icons stay legible.
    /// A single heavy wave for 16 px, where two waves blur together.
    static let tinySoundWaves = [
        SoundWave(radius: 255, strokeWidth: 115, opacity: 1.0)
    ]

    static let simplifiedSoundWaves = [
        SoundWave(radius: 240, strokeWidth: 80, opacity: 1.0),
        SoundWave(radius: 365, strokeWidth: 80, opacity: 0.6)
    ]

    static var triangleVertices: [CGPoint] {
        [pointerTip, pointerFlatSideBottom, pointerFlatSideTop]
    }

    static func cornerRadius(forVertexAt vertexIndex: Int) -> CGFloat {
        vertexIndex == 0 ? pointerTipCornerRadius : pointerFlatSideCornerRadius
    }

    /// For each corner: the point where the rounding starts, the corner
    /// itself (used as the curve's control point), and where it ends.
    static var roundedTriangleCorners: [(curveStart: CGPoint, corner: CGPoint, curveEnd: CGPoint)] {
        let vertices = triangleVertices
        return vertices.indices.map { vertexIndex in
            let previousVertex = vertices[(vertexIndex + vertices.count - 1) % vertices.count]
            let currentVertex = vertices[vertexIndex]
            let nextVertex = vertices[(vertexIndex + 1) % vertices.count]
            let roundingDistance = cornerRadius(forVertexAt: vertexIndex)
            return (
                curveStart: point(from: currentVertex, toward: previousVertex, distance: roundingDistance),
                corner: currentVertex,
                curveEnd: point(from: currentVertex, toward: nextVertex, distance: roundingDistance)
            )
        }
    }

    static func soundWaveEndpoints(radius: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let halfAngleInRadians = soundWaveArcHalfAngleInDegrees * .pi / 180
        return (
            start: CGPoint(x: soundWaveArcCenter.x + radius * cos(halfAngleInRadians),
                           y: soundWaveArcCenter.y - radius * sin(halfAngleInRadians)),
            end: CGPoint(x: soundWaveArcCenter.x + radius * cos(halfAngleInRadians),
                         y: soundWaveArcCenter.y + radius * sin(halfAngleInRadians))
        )
    }

    private static func point(from startPoint: CGPoint, toward targetPoint: CGPoint, distance: CGFloat) -> CGPoint {
        let deltaX = targetPoint.x - startPoint.x
        let deltaY = targetPoint.y - startPoint.y
        let length = sqrt(deltaX * deltaX + deltaY * deltaY)
        return CGPoint(x: startPoint.x + deltaX / length * distance, y: startPoint.y + deltaY / length * distance)
    }
}

// MARK: - Colors

enum BrandColors {
    static let backgroundTopLeft = NSColor(srgbRed: 0.165, green: 0.247, blue: 0.659, alpha: 1)      // #2A3FA8
    static let backgroundBottomRight = NSColor(srgbRed: 0.047, green: 0.078, blue: 0.251, alpha: 1)  // #0C1440
    static let cursorBlue = NSColor(srgbRed: 0.2, green: 0.502, blue: 1.0, alpha: 1)                 // #3380FF, the in-app cursor
    static let triangleTop = NSColor(srgbRed: 0.486, green: 0.722, blue: 1.0, alpha: 1)              // #7CB8FF
    static let triangleBottom = NSColor(srgbRed: 0.18, green: 0.424, blue: 1.0, alpha: 1)            // #2E6CFF

    static let wordmarkHeyOnLight = NSColor(srgbRed: 0.357, green: 0.42, blue: 0.549, alpha: 1)      // #5B6B8C
    static let wordmarkSonaOnLight = NSColor(srgbRed: 0.055, green: 0.078, blue: 0.188, alpha: 1)    // #0E1430
    static let wordmarkHeyOnDark = NSColor(srgbRed: 0.616, green: 0.706, blue: 0.878, alpha: 1)      // #9DB4E0
    static let wordmarkSonaOnDark = NSColor.white

    static func svgHex(_ color: NSColor) -> String {
        let srgbColor = color.usingColorSpace(.sRGB)!
        return String(
            format: "#%02X%02X%02X",
            Int((srgbColor.redComponent * 255).rounded()),
            Int((srgbColor.greenComponent * 255).rounded()),
            Int((srgbColor.blueComponent * 255).rounded())
        )
    }
}

// MARK: - Drawing

/// Draws the full icon into `context`, scaled so the 1024 canvas fills
/// `pixelSize`. The context must already be flipped to a top-left origin.
func drawAppIcon(in context: CGContext, pixelSize: CGFloat) {
    let scale = pixelSize / BrandGeometry.canvasSize
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let iconBodyPath = CGPath(
        roundedRect: BrandGeometry.iconBodyRect,
        cornerWidth: BrandGeometry.iconBodyCornerRadius,
        cornerHeight: BrandGeometry.iconBodyCornerRadius,
        transform: nil
    )

    // Soft drop shadow under the body, as on Apple's macOS icon template.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(iconBodyPath)
    context.setFillColor(BrandColors.backgroundBottomRight.cgColor)
    context.fillPath()
    context.restoreGState()

    // Body: indigo gradient, a blue glow behind the mark, and a top sheen.
    context.saveGState()
    context.addPath(iconBodyPath)
    context.clip()

    let backgroundGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [BrandColors.backgroundTopLeft.cgColor, BrandColors.backgroundBottomRight.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backgroundGradient,
        start: CGPoint(x: BrandGeometry.iconBodyRect.minX, y: BrandGeometry.iconBodyRect.minY),
        end: CGPoint(x: BrandGeometry.iconBodyRect.maxX, y: BrandGeometry.iconBodyRect.maxY),
        options: []
    )

    let glowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [BrandColors.cursorBlue.withAlphaComponent(0.5).cgColor, BrandColors.cursorBlue.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    let tiltedTriangleCentroid = BrandGeometry.triangleCentroid.applying(BrandGeometry.markTransform)
    context.drawRadialGradient(
        glowGradient,
        startCenter: tiltedTriangleCentroid, startRadius: 0,
        endCenter: tiltedTriangleCentroid, endRadius: 400,
        options: []
    )

    let sheenGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheenGradient,
        start: CGPoint(x: 0, y: BrandGeometry.iconBodyRect.minY),
        end: CGPoint(x: 0, y: BrandGeometry.iconBodyRect.midY),
        options: []
    )
    context.restoreGState()

    let soundWavesForThisSize: [BrandGeometry.SoundWave]
    if pixelSize <= 16 {
        soundWavesForThisSize = BrandGeometry.tinySoundWaves
    } else if pixelSize <= 64 {
        soundWavesForThisSize = BrandGeometry.simplifiedSoundWaves
    } else {
        soundWavesForThisSize = BrandGeometry.detailedSoundWaves
    }
    drawMark(in: context, soundWaves: soundWavesForThisSize, drawsTriangleGlow: pixelSize > 64)

    context.restoreGState()
}

/// Draws the speaker-cursor and sound waves in canvas coordinates.
func drawMark(in context: CGContext, soundWaves: [BrandGeometry.SoundWave], drawsTriangleGlow: Bool) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    context.saveGState()
    context.concatenate(BrandGeometry.markTransform)
    defer { context.restoreGState() }

    // Sound waves.
    let halfAngleInRadians = BrandGeometry.soundWaveArcHalfAngleInDegrees * .pi / 180
    context.setLineCap(.round)
    for soundWave in soundWaves {
        context.beginPath()
        context.addArc(
            center: BrandGeometry.soundWaveArcCenter,
            radius: soundWave.radius,
            startAngle: -halfAngleInRadians,
            endAngle: halfAngleInRadians,
            clockwise: false
        )
        context.setLineWidth(soundWave.strokeWidth)
        context.setStrokeColor(NSColor.white.withAlphaComponent(soundWave.opacity).cgColor)
        context.strokePath()
    }

    // Speaker-cursor triangle with rounded corners, a glow, and a gradient.
    let trianglePath = CGMutablePath()
    let roundedCorners = BrandGeometry.roundedTriangleCorners
    trianglePath.move(to: roundedCorners[0].curveEnd)
    for cornerIndex in 1...roundedCorners.count {
        let roundedCorner = roundedCorners[cornerIndex % roundedCorners.count]
        trianglePath.addLine(to: roundedCorner.curveStart)
        trianglePath.addQuadCurve(to: roundedCorner.curveEnd, control: roundedCorner.corner)
    }
    trianglePath.closeSubpath()

    context.saveGState()
    context.setShadow(offset: .zero, blur: drawsTriangleGlow ? 60 : 0, color: BrandColors.cursorBlue.withAlphaComponent(0.9).cgColor)
    context.addPath(trianglePath)
    context.setFillColor(BrandColors.triangleBottom.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(trianglePath)
    context.clip()
    let triangleGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [BrandColors.triangleTop.cgColor, BrandColors.triangleBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    let triangleBounds = trianglePath.boundingBox
    context.drawLinearGradient(
        triangleGradient,
        start: CGPoint(x: triangleBounds.midX, y: triangleBounds.minY),
        end: CGPoint(x: triangleBounds.midX, y: triangleBounds.maxY),
        options: []
    )
    context.restoreGState()
}

// MARK: - Bitmap Helpers

func makeBitmap(pixelWidth: Int, pixelHeight: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!.retagging(with: .sRGB)!
}

func writePNG(_ bitmap: NSBitmapImageRep, to fileURL: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BrandAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(fileURL.lastPathComponent)"])
    }
    try pngData.write(to: fileURL)
    print("wrote \(fileURL.path)")
}

/// Runs `drawing` with a CGContext flipped to a top-left origin.
func drawFlipped(into bitmap: NSBitmapImageRep, drawing: (CGContext) -> Void) {
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
    context.scaleBy(x: 1, y: -1)
    drawing(context)
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Outputs

func generateAppIconPNGs(appIconFolderURL: URL) throws {
    for iconPixelSize in [16, 32, 64, 128, 256, 512, 1024] {
        let iconBitmap = makeBitmap(pixelWidth: iconPixelSize, pixelHeight: iconPixelSize)
        drawFlipped(into: iconBitmap) { context in
            drawAppIcon(in: context, pixelSize: CGFloat(iconPixelSize))
        }
        try writePNG(iconBitmap, to: appIconFolderURL.appendingPathComponent("\(iconPixelSize)-mac.png"))
    }
}

func generateLogoPNG(fileURL: URL, heyColor: NSColor, sonaColor: NSColor) throws {
    let logoHeight: CGFloat = 440
    let markSize: CGFloat = 440
    let wordmarkFontSize: CGFloat = 210

    let roundedDescriptor = NSFont.systemFont(ofSize: wordmarkFontSize, weight: .bold).fontDescriptor.withDesign(.rounded)!
    let sonaFont = NSFont(descriptor: roundedDescriptor, size: wordmarkFontSize)!
    let heyDescriptor = NSFont.systemFont(ofSize: wordmarkFontSize, weight: .medium).fontDescriptor.withDesign(.rounded)!
    let heyFont = NSFont(descriptor: heyDescriptor, size: wordmarkFontSize)!

    let wordmark = NSMutableAttributedString(string: "hey", attributes: [.font: heyFont, .foregroundColor: heyColor, .kern: -2])
    wordmark.append(NSAttributedString(string: "Sona", attributes: [.font: sonaFont, .foregroundColor: sonaColor, .kern: -2]))
    let wordmarkSize = wordmark.size()

    // The icon canvas has built-in padding around the body, so a small gap is enough.
    let gapBetweenMarkAndWordmark: CGFloat = 4
    let trailingPadding: CGFloat = 60
    let logoWidth = markSize + gapBetweenMarkAndWordmark + wordmarkSize.width + trailingPadding

    let logoBitmap = makeBitmap(pixelWidth: Int(logoWidth.rounded()), pixelHeight: Int(logoHeight))
    drawFlipped(into: logoBitmap) { context in
        drawAppIcon(in: context, pixelSize: markSize)
    }

    // Text draws in AppKit's normal bottom-left coordinates.
    let graphicsContext = NSGraphicsContext(bitmapImageRep: logoBitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    wordmark.draw(at: CGPoint(
        x: markSize + gapBetweenMarkAndWordmark,
        y: (logoHeight - wordmarkSize.height) / 2
    ))
    NSGraphicsContext.restoreGraphicsState()

    try writePNG(logoBitmap, to: fileURL)
}

func generateMarkSVG(fileURL: URL) throws {
    let iconBody = BrandGeometry.iconBodyRect
    let roundedCorners = BrandGeometry.roundedTriangleCorners

    func formatted(_ point: CGPoint) -> String {
        String(format: "%.1f %.1f", point.x, point.y)
    }

    var trianglePathData = "M \(formatted(roundedCorners[0].curveEnd))"
    for cornerIndex in 1...roundedCorners.count {
        let roundedCorner = roundedCorners[cornerIndex % roundedCorners.count]
        trianglePathData += " L \(formatted(roundedCorner.curveStart)) Q \(formatted(roundedCorner.corner)) \(formatted(roundedCorner.curveEnd))"
    }
    trianglePathData += " Z"

    let tiltedTriangleCentroid = BrandGeometry.triangleCentroid.applying(BrandGeometry.markTransform)
    let transform = BrandGeometry.markTransform
    let markTransformSVG = String(format: "matrix(%.5f %.5f %.5f %.5f %.2f %.2f)", transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty)

    let soundWaveElements = BrandGeometry.detailedSoundWaves.map { soundWave -> String in
        let endpoints = BrandGeometry.soundWaveEndpoints(radius: soundWave.radius)
        return """
          <path d="M \(formatted(endpoints.start)) A \(soundWave.radius) \(soundWave.radius) 0 0 1 \(formatted(endpoints.end))" fill="none" stroke="#FFFFFF" stroke-opacity="\(soundWave.opacity)" stroke-width="\(soundWave.strokeWidth)" stroke-linecap="round"/>
        """
    }.joined(separator: "\n")

    let svgText = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <title>heySona</title>
      <defs>
        <linearGradient id="background" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="\(BrandColors.svgHex(BrandColors.backgroundTopLeft))"/>
          <stop offset="1" stop-color="\(BrandColors.svgHex(BrandColors.backgroundBottomRight))"/>
        </linearGradient>
        <radialGradient id="glow" cx="\(String(format: "%.1f", tiltedTriangleCentroid.x))" cy="\(String(format: "%.1f", tiltedTriangleCentroid.y))" r="400" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(BrandColors.svgHex(BrandColors.cursorBlue))" stop-opacity="0.5"/>
          <stop offset="1" stop-color="\(BrandColors.svgHex(BrandColors.cursorBlue))" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/>
          <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
        </linearGradient>
        <linearGradient id="triangle" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(BrandColors.svgHex(BrandColors.triangleTop))"/>
          <stop offset="1" stop-color="\(BrandColors.svgHex(BrandColors.triangleBottom))"/>
        </linearGradient>
        <filter id="triangleGlow" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="30"/>
        </filter>
      </defs>
      <rect x="\(iconBody.minX)" y="\(iconBody.minY)" width="\(iconBody.width)" height="\(iconBody.height)" rx="\(BrandGeometry.iconBodyCornerRadius)" fill="url(#background)"/>
      <rect x="\(iconBody.minX)" y="\(iconBody.minY)" width="\(iconBody.width)" height="\(iconBody.height)" rx="\(BrandGeometry.iconBodyCornerRadius)" fill="url(#glow)"/>
      <rect x="\(iconBody.minX)" y="\(iconBody.minY)" width="\(iconBody.width)" height="\(iconBody.height)" rx="\(BrandGeometry.iconBodyCornerRadius)" fill="url(#sheen)"/>
      <g transform="\(markTransformSVG)">
    \(soundWaveElements)
        <path d="\(trianglePathData)" fill="\(BrandColors.svgHex(BrandColors.cursorBlue))" fill-opacity="0.9" filter="url(#triangleGlow)"/>
        <path d="\(trianglePathData)" fill="url(#triangle)"/>
      </g>
    </svg>

    """
    try svgText.write(to: fileURL, atomically: true, encoding: .utf8)
    print("wrote \(fileURL.path)")
}

// MARK: - Main

let repositoryRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconFolderURL = repositoryRootURL.appendingPathComponent("leanring-buddy/Assets.xcassets/AppIcon.appiconset")
let brandingFolderURL = repositoryRootURL.appendingPathComponent("branding")

guard FileManager.default.fileExists(atPath: appIconFolderURL.path) else {
    print("Run this from the repository root (couldn't find \(appIconFolderURL.path)).")
    exit(1)
}
try FileManager.default.createDirectory(at: brandingFolderURL, withIntermediateDirectories: true)

try generateAppIconPNGs(appIconFolderURL: appIconFolderURL)
try generateMarkSVG(fileURL: brandingFolderURL.appendingPathComponent("heysona-mark.svg"))
try generateLogoPNG(
    fileURL: brandingFolderURL.appendingPathComponent("heysona-logo-light.png"),
    heyColor: BrandColors.wordmarkHeyOnLight,
    sonaColor: BrandColors.wordmarkSonaOnLight
)
try generateLogoPNG(
    fileURL: brandingFolderURL.appendingPathComponent("heysona-logo-dark.png"),
    heyColor: BrandColors.wordmarkHeyOnDark,
    sonaColor: BrandColors.wordmarkSonaOnDark
)

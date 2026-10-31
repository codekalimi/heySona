//
//  ScreenDrawingAnnotations.swift
//  leanring-buddy
//
//  Lets heySona draw on the user's screen while it answers: circles,
//  highlight boxes, arrows, and underlines, each with an optional short
//  label. Claude adds drawing tags at the end of its reply (like the
//  existing [POINT:...] tag), they're parsed here, converted from
//  screenshot pixels to display points, and rendered on the transparent
//  cursor overlay with a "sketching in" animation.
//
//  Tags use the screenshot's pixel coordinates (top-left origin):
//    [CIRCLE:x,y,radius:label:screenN]
//    [BOX:x,y,width,height:label:screenN]
//    [ARROW:fromX,fromY,toX,toY:label:screenN]
//    [UNDERLINE:fromX,fromY,toX,toY:label:screenN]
//  The label and :screenN parts are optional.
//

import SwiftUI

// MARK: - Model

enum ScreenDrawingShape: Equatable {
    case circle(center: CGPoint, radius: CGFloat)
    case box(rect: CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case underline(start: CGPoint, end: CGPoint)
}

/// One drawing, already converted to the target display's local point
/// coordinates (top-left origin), ready for that screen's overlay.
struct ScreenDrawing: Identifiable, Equatable {
    let id = UUID()
    let shape: ScreenDrawingShape
    let label: String?
    /// The display this drawing belongs to, in AppKit global coordinates.
    let displayFrame: CGRect
    /// Position in the reply's sequence, used to stagger the animations.
    let drawingOrder: Int
}

// MARK: - Parsing

enum ScreenDrawingTagParser {
    /// More than this many drawings at once becomes visual noise.
    static let maximumDrawingCount = 6

    private struct ParsedDrawingTag {
        let kind: String
        let numbers: [CGFloat]
        let label: String?
        let screenNumber: Int?
    }

    /// Matches every drawing tag anywhere in the reply. The label part can't
    /// be "screenN" itself, so a tag with only a screen number parses right.
    private static let drawingTagPattern =
        #"\[(CIRCLE|BOX|ARROW|UNDERLINE):\s*([-\d.,\s]+?)\s*(?::(?!screen\d+\])([^\]:]+))?(?::screen(\d+))?\]"#

    /// Returns the reply with all drawing tags removed (so they're never
    /// spoken) and the drawings converted for the overlay.
    static func extractDrawings(
        from responseText: String,
        screenCaptures: [CompanionScreenCapture]
    ) -> (textWithoutDrawingTags: String, drawings: [ScreenDrawing]) {
        guard let drawingTagRegex = try? NSRegularExpression(pattern: drawingTagPattern, options: [.caseInsensitive]) else {
            return (responseText, [])
        }

        let fullTextRange = NSRange(responseText.startIndex..., in: responseText)
        let tagMatches = drawingTagRegex.matches(in: responseText, range: fullTextRange)
        guard !tagMatches.isEmpty else { return (responseText, []) }

        var parsedDrawingTags: [ParsedDrawingTag] = []
        for tagMatch in tagMatches {
            func capturedText(_ groupIndex: Int) -> String? {
                guard let groupRange = Range(tagMatch.range(at: groupIndex), in: responseText) else { return nil }
                let groupText = String(responseText[groupRange]).trimmingCharacters(in: .whitespaces)
                return groupText.isEmpty ? nil : groupText
            }

            guard let kind = capturedText(1)?.uppercased(), let numbersText = capturedText(2) else { continue }
            let numbers = numbersText
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { CGFloat($0) }

            parsedDrawingTags.append(ParsedDrawingTag(
                kind: kind,
                numbers: numbers,
                label: capturedText(3),
                screenNumber: capturedText(4).flatMap { Int($0) }
            ))
        }

        let textWithoutDrawingTags = drawingTagRegex
            .stringByReplacingMatches(in: responseText, range: fullTextRange, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var drawings: [ScreenDrawing] = []
        for parsedDrawingTag in parsedDrawingTags.prefix(maximumDrawingCount) {
            if let drawing = makeDrawing(
                from: parsedDrawingTag,
                drawingOrder: drawings.count,
                screenCaptures: screenCaptures
            ) {
                drawings.append(drawing)
            }
        }

        return (textWithoutDrawingTags, drawings)
    }

    private static func makeDrawing(
        from parsedDrawingTag: ParsedDrawingTag,
        drawingOrder: Int,
        screenCaptures: [CompanionScreenCapture]
    ) -> ScreenDrawing? {
        // Same rule as pointing: the numbered screen, else the cursor's screen.
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parsedDrawingTag.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()
        guard let targetScreenCapture else { return nil }

        // Claude works in screenshot pixels; the overlay uses display points.
        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let horizontalScale = CGFloat(targetScreenCapture.displayWidthInPoints) / screenshotWidth
        let verticalScale = CGFloat(targetScreenCapture.displayHeightInPoints) / screenshotHeight

        func displayPoint(x: CGFloat, y: CGFloat) -> CGPoint {
            let clampedX = max(0, min(x, screenshotWidth))
            let clampedY = max(0, min(y, screenshotHeight))
            return CGPoint(x: clampedX * horizontalScale, y: clampedY * verticalScale)
        }

        let numbers = parsedDrawingTag.numbers
        let shape: ScreenDrawingShape
        switch parsedDrawingTag.kind {
        case "CIRCLE":
            guard numbers.count >= 3, numbers[2] > 0 else { return nil }
            shape = .circle(
                center: displayPoint(x: numbers[0], y: numbers[1]),
                radius: numbers[2] * horizontalScale
            )
        case "BOX":
            guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            let topLeft = displayPoint(x: numbers[0], y: numbers[1])
            let bottomRight = displayPoint(x: numbers[0] + numbers[2], y: numbers[1] + numbers[3])
            shape = .box(rect: CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            ))
        case "ARROW", "UNDERLINE":
            guard numbers.count >= 4 else { return nil }
            let start = displayPoint(x: numbers[0], y: numbers[1])
            let end = displayPoint(x: numbers[2], y: numbers[3])
            guard hypot(end.x - start.x, end.y - start.y) > 8 else { return nil }
            shape = parsedDrawingTag.kind == "ARROW" ? .arrow(start: start, end: end) : .underline(start: start, end: end)
        default:
            return nil
        }

        return ScreenDrawing(
            shape: shape,
            label: parsedDrawingTag.label,
            displayFrame: targetScreenCapture.displayFrame,
            drawingOrder: drawingOrder
        )
    }

    // MARK: - Prompt

    /// Appended to the system prompt while "Draw on screen" is on.
    static let systemPromptSection = """

    drawing on screen:
    besides pointing, you can draw on the user's screen to show them things. it makes your help far more concrete, so whenever the question is about something visible (where something is, how to do something in the app they're looking at, what part of the screen matters), show it: point at the main thing and draw around the rest. skip drawing for general questions that have nothing to do with the screen.

    put each drawing tag right after the sentence it belongs to: it appears on the user's real screen the moment you say that sentence, so draw as you talk ("this is the command you typed. [UNDERLINE:…] the shell reads it here. [BOX:…]"). label drawings with the real text you see on screen (the exact command, file name, or value), not generic words. use the same pixel coordinates as pointing (top-left origin, the image's labeled dimensions). each tag can end with a short label (1-4 words) and :screenN when it's not on the cursor's screen.
    - [CIRCLE:x,y,radius:label] circle a button, icon, or small element. make the radius a bit larger than the element.
    - [BOX:x,y,width,height:label] highlight a region, panel, paragraph, or setting. x,y is the top-left corner.
    - [ARROW:fromX,fromY,toX,toY:label] arrow pointing to something, e.g. from empty space toward a menu. the arrowhead is at toX,toY.
    - [UNDERLINE:fromX,fromY,toX,toY] underline a line of text, just below the text.

    use at most four drawings, and only on things you can actually see in the screenshot. for steps, label them "1", "2", "3" in order. never mention the tags or coordinates out loud.

    example: "open the view menu. [CIRCLE:212,12,24:view menu] then pick show sidebar. [ARROW:420,180,240,52:show sidebar] [POINT:212,12:view menu]"
    """
}

// MARK: - Rendering

/// Renders the drawings for one screen on top of its overlay window.
struct ScreenDrawingLayerView: View {
    let drawingsOnThisScreen: [ScreenDrawing]

    var body: some View {
        GeometryReader { screenGeometry in
            ZStack {
                ForEach(drawingsOnThisScreen) { screenDrawing in
                    AnimatedScreenDrawingView(screenDrawing: screenDrawing, screenSize: screenGeometry.size)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct AnimatedScreenDrawingView: View {
    let screenDrawing: ScreenDrawing
    /// Used to keep labels on screen near the edges (e.g. the menu bar).
    let screenSize: CGSize

    /// 0 → 1 as the stroke "sketches" itself in.
    @State private var strokeDrawingProgress: CGFloat = 0
    @State private var labelOpacity: Double = 0

    private static let strokeColor = DS.Colors.overlayCursorBlue
    private static let strokeWidth: CGFloat = 4
    private static let delayBetweenDrawingsInSeconds = 0.35
    private static let strokeAnimationDurationInSeconds = 0.55

    var body: some View {
        ZStack {
            if case .box(let rect) = screenDrawing.shape {
                // A soft fill makes a highlighted region readable as one block.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Self.strokeColor.opacity(0.12 * strokeDrawingProgress))
                    .frame(width: rect.width + 12, height: rect.height + 12)
                    .position(x: rect.midX, y: rect.midY)
            }

            ScreenDrawingStrokePath(shape: screenDrawing.shape)
                .trim(from: 0, to: strokeDrawingProgress)
                .stroke(
                    Self.strokeColor,
                    style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Self.strokeColor.opacity(0.8), radius: 6)
                .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)

            if let label = screenDrawing.label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Self.strokeColor)
                            .shadow(color: Self.strokeColor.opacity(0.5), radius: 6)
                    )
                    .fixedSize()
                    .position(labelPosition)
                    .opacity(labelOpacity)
            }
        }
        .onAppear {
            let startDelay = Double(screenDrawing.drawingOrder) * Self.delayBetweenDrawingsInSeconds
            withAnimation(.easeOut(duration: Self.strokeAnimationDurationInSeconds).delay(startDelay)) {
                strokeDrawingProgress = 1
            }
            withAnimation(.easeOut(duration: 0.3).delay(startDelay + Self.strokeAnimationDurationInSeconds * 0.6)) {
                labelOpacity = 1
            }
        }
    }

    /// Puts the label just outside the shape, where it won't cover the
    /// target, then nudges it fully onto the screen.
    private var labelPosition: CGPoint {
        let preferredLabelPosition: CGPoint
        switch screenDrawing.shape {
        case .circle(let center, let radius):
            let aboveCircleY = center.y - radius * 0.7 - 18
            // Near the top (menu bar items), there's no room above: go below.
            let labelY = aboveCircleY < 24 ? center.y + radius + 22 : aboveCircleY
            preferredLabelPosition = CGPoint(x: center.x + radius * 0.7 + 30, y: labelY)
        case .box(let rect):
            let aboveBoxY = rect.minY - 20
            let labelY = aboveBoxY < 24 ? rect.maxY + 22 : aboveBoxY
            preferredLabelPosition = CGPoint(x: rect.minX + 40, y: labelY)
        case .arrow(let start, _):
            // At the arrow's tail, so the arrow reads "label → target".
            preferredLabelPosition = CGPoint(x: start.x, y: start.y + 18)
        case .underline(let start, let end):
            preferredLabelPosition = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 18)
        }

        let edgeMarginForLabelCenter: CGFloat = 60
        return CGPoint(
            x: max(edgeMarginForLabelCenter, min(preferredLabelPosition.x, screenSize.width - edgeMarginForLabelCenter)),
            y: max(16, min(preferredLabelPosition.y, screenSize.height - 16))
        )
    }
}

/// The stroke outline of a drawing. A Shape so `.trim` can animate it.
private struct ScreenDrawingStrokePath: Shape {
    let shape: ScreenDrawingShape

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch shape {
        case .circle(let center, let radius):
            // Start at the top-left and go slightly past a full turn, like a
            // hand-drawn circle that overlaps where it began.
            let startAngle = Angle.degrees(-135)
            path.addArc(center: center, radius: radius + 6, startAngle: startAngle, endAngle: startAngle + .degrees(375), clockwise: false)

        case .box(let rect):
            path.addRoundedRect(in: rect.insetBy(dx: -6, dy: -6), cornerSize: CGSize(width: 10, height: 10), style: .continuous)

        case .arrow(let start, let end):
            path.move(to: start)
            // A gentle curve reads as hand-drawn and avoids crossing the target.
            let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let lineLength = hypot(end.x - start.x, end.y - start.y)
            let perpendicularOffset = lineLength * 0.12
            let lineAngle = atan2(end.y - start.y, end.x - start.x)
            let curveControlPoint = CGPoint(
                x: midpoint.x - sin(lineAngle) * perpendicularOffset,
                y: midpoint.y + cos(lineAngle) * perpendicularOffset
            )
            path.addQuadCurve(to: end, control: curveControlPoint)

            // Arrowhead, aligned with the curve's final direction.
            let arrowheadAngle = atan2(end.y - curveControlPoint.y, end.x - curveControlPoint.x)
            let arrowheadLength: CGFloat = 16
            for arrowheadSideAngle in [arrowheadAngle + .pi * 0.82, arrowheadAngle - .pi * 0.82] {
                path.move(to: end)
                path.addLine(to: CGPoint(
                    x: end.x + cos(arrowheadSideAngle) * arrowheadLength,
                    y: end.y + sin(arrowheadSideAngle) * arrowheadLength
                ))
            }

        case .underline(let start, let end):
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }
}

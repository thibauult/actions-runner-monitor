import AppKit

/// The GitHub mark, drawn from its 24x24 SVG path so the menu bar needs no bundled asset.
/// It is a template image, so macOS tints it for light/dark menu bars.
enum GitHubMark {
    private static let path = """
    M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 \
    0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7 \
    c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998 \
    .108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22 \
    -.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 \
    2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 \
    0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 \
    0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12z
    """

    static let image: NSImage = {
        let side: CGFloat = 16
        let bezier = parse(path)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let scale = side / 24
            let transform = AffineTransform(scaleByX: scale, byY: scale)
            let scaled = bezier.copy() as! NSBezierPath
            scaled.transform(using: transform)
            NSColor.black.setFill()
            scaled.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The mark on a dark rounded square, for the app icon (shown in notifications).
    /// `build.sh` renders it into the bundle with `--write-icon`.
    static func writeAppIcon(to url: URL, side: Int = 1024) throws {
        let size = CGFloat(side)
        let bezier = parse(path)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let tile = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            NSColor(white: 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: size * 0.2, yRadius: size * 0.2).fill()

            let markSide = size * 0.6
            let scale = markSide / 24
            let offset = (size - markSide) / 2
            var transform = AffineTransform(translationByX: offset, byY: offset)
            transform.prepend(AffineTransform(scaleByX: scale, byY: scale))
            let scaled = bezier.copy() as! NSBezierPath
            scaled.transform(using: transform)
            NSColor.white.setFill()
            scaled.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    /// Minimal SVG path parser: only the commands the mark uses (M, c, C, z).
    private static func parse(_ d: String) -> NSBezierPath {
        let bezier = NSBezierPath()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero

        func flush() {
            switch command {
            case "M" where numbers.count >= 2:
                current = CGPoint(x: numbers[0], y: numbers[1])
                bezier.move(to: current)
            case "c":
                var i = 0
                while i + 6 <= numbers.count {
                    let n = numbers[i..<i + 6]
                    let p = Array(n)
                    bezier.curve(
                        to: CGPoint(x: current.x + p[4], y: current.y + p[5]),
                        controlPoint1: CGPoint(x: current.x + p[0], y: current.y + p[1]),
                        controlPoint2: CGPoint(x: current.x + p[2], y: current.y + p[3]))
                    current = CGPoint(x: current.x + p[4], y: current.y + p[5])
                    i += 6
                }
            case "C":
                var i = 0
                while i + 6 <= numbers.count {
                    let p = Array(numbers[i..<i + 6])
                    bezier.curve(
                        to: CGPoint(x: p[4], y: p[5]),
                        controlPoint1: CGPoint(x: p[0], y: p[1]),
                        controlPoint2: CGPoint(x: p[2], y: p[3]))
                    current = CGPoint(x: p[4], y: p[5])
                    i += 6
                }
            default:
                break
            }
            numbers.removeAll()
        }

        var token = ""
        func endToken() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        for ch in d {
            if ch.isLetter {
                endToken()
                flush()
                command = ch
                if ch == "z" { bezier.close() }
            } else if ch == "-" {
                endToken()
                token = "-"
            } else if ch == "." {
                if token.contains(".") { endToken() }
                token.append(ch)
            } else if ch.isNumber {
                token.append(ch)
            } else {
                endToken()
            }
        }
        endToken()
        flush()
        return bezier
    }
}

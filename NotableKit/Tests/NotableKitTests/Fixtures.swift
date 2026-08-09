import CoreGraphics
import Foundation
import ImageIO

enum Fixtures {
    struct FixtureError: Error { let message: String }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "NotableKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A PDF whose pages are distinguishable: page *i* has a filled bar `i + 1` units tall.
    @discardableResult
    static func writePDF(
        at url: URL,
        pageCount: Int,
        size: CGSize = CGSize(width: 612, height: 792)
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw FixtureError(message: "could not create PDF context at \(url.path)")
        }
        for page in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: CGFloat(page + 1) * 10))
            context.endPage()
        }
        context.closePDF()
        return url
    }

    /// A hand-built one-page PDF carrying a `/Rotate` entry — `CGContext`'s PDF writer has no way
    /// to set one. Same content as `writePDF`: a black bar along the bottom of the unrotated page.
    @discardableResult
    static func writeRotatedPDF(
        at url: URL,
        rotation: Int,
        size: CGSize = CGSize(width: 100, height: 200)
    ) throws -> URL {
        let width = Int(size.width)
        let height = Int(size.height)
        let content = "0 0 0 rg 0 0 \(width) 10 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Rotate \(rotation) "
                + "/Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let startXref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(startXref)\n%%EOF\n"

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(pdf.utf8).write(to: url)
        return url
    }

    @discardableResult
    static func writePNG(
        at url: URL,
        size: CGSize = CGSize(width: 100, height: 200),
        gray: CGFloat = 0.5
    ) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FixtureError(message: "could not create bitmap context") }

        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw FixtureError(message: "could not encode PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError(message: "could not write PNG to \(url.path)")
        }
        return url
    }

    /// RGBA bytes of an image, for asserting what a renderer actually put on screen.
    static func pixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw FixtureError(message: "could not create sampling context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    static func containsNonWhitePixel(_ image: CGImage) throws -> Bool {
        let bytes = try pixels(of: image)
        return stride(from: 0, to: bytes.count, by: 4).contains { index in
            bytes[index] < 250 || bytes[index + 1] < 250 || bytes[index + 2] < 250
        }
    }
}

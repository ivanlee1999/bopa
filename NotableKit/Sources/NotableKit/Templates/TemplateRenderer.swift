import CoreGraphics
import Foundation

/// Rasterizes a template so it can sit behind ink on the canvas, or fill a thumbnail in a picker.
///
/// Notable's layout rule, mirrored here: the asset is scaled so its **width matches the page
/// width** and anchored at the top of the page; the page itself scrolls on forever below it. A
/// repeating image tiles down that scroll instead of stopping.
///
/// All rectangles are in page coordinates with y increasing downwards; `viewport` is the slice of
/// the page to draw (its origin is the scroll offset).
public struct TemplateRenderer: Sendable {
    public let store: TemplateStore

    public init(store: TemplateStore) {
        self.store = store
    }

    // MARK: - Drawing

    /// Draw into a context whose CTM is already page coordinates, y-down.
    public func draw(
        _ template: Template,
        in context: CGContext,
        viewport: CGRect,
        pageWidth: CGFloat
    ) throws {
        switch template.source {
        case .native(let native):
            NativeTemplateRenderer.draw(native, in: context, viewport: viewport, pageWidth: pageWidth)

        case .image(let ref, let repeating):
            try fillWhite(context, viewport)
            guard let image = ImageSupport.image(at: try assetURL(ref)) else {
                throw TemplateError.renderFailed
            }
            let scale = pageWidth / CGFloat(image.width)
            let drawnHeight = CGFloat(image.height) * scale
            guard drawnHeight > 0 else { throw TemplateError.renderFailed }

            var top: CGFloat = 0
            repeat {
                let rect = CGRect(x: 0, y: top, width: pageWidth, height: drawnHeight)
                if rect.intersects(viewport) {
                    draw(image, in: rect, context: context)
                }
                top += drawnHeight
            } while repeating && top < viewport.maxY

        case .pdf(let ref, let pageIndex):
            try fillWhite(context, viewport)
            let document = try PDFSupport.document(at: try assetURL(ref))
            let page = try PDFSupport.page(document, at: pageIndex)
            draw(page, in: context, pageWidth: pageWidth)
        }
    }

    /// Render a slice of a templated page.
    ///
    /// - Parameters:
    ///   - pageWidth: width of the note page in page units; the template is fitted to it.
    ///   - viewport: page-coordinate rectangle to render (origin = scroll offset).
    ///   - scale: pixels per page unit.
    public func image(
        for template: Template,
        pageWidth: CGFloat,
        viewport: CGRect,
        scale: CGFloat = 1
    ) throws -> CGImage {
        let pixelWidth = Int((viewport.width * scale).rounded())
        let pixelHeight = Int((viewport.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { throw TemplateError.renderFailed }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TemplateError.renderFailed }

        // Flip into page coordinates (y down), then move the viewport origin to (0, 0).
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -viewport.minX, y: -viewport.minY)
        context.interpolationQuality = .high

        try draw(template, in: context, viewport: viewport, pageWidth: pageWidth)

        guard let image = context.makeImage() else { throw TemplateError.renderFailed }
        return image
    }

    /// Preview of the top of a template, for a picker. The template is fitted to `size.width`.
    public func thumbnail(for template: Template, size: CGSize, scale: CGFloat = 2) throws -> CGImage {
        try image(
            for: template,
            pageWidth: size.width,
            viewport: CGRect(origin: .zero, size: size),
            scale: scale
        )
    }

    /// Height the template occupies on the page at a given page width — how far down the page the
    /// pre-printed part reaches. `nil` for native grids, which have no end.
    public func drawnHeight(for template: Template, pageWidth: CGFloat) throws -> CGFloat? {
        switch template.source {
        case .native:
            return nil
        case .image(let ref, _):
            guard let size = ImageSupport.pixelSize(at: try assetURL(ref)), size.width > 0 else {
                throw TemplateError.renderFailed
            }
            return size.height * (pageWidth / size.width)
        case .pdf(let ref, let pageIndex):
            let document = try PDFSupport.document(at: try assetURL(ref))
            let size = PDFSupport.displaySize(of: try PDFSupport.page(document, at: pageIndex))
            guard size.width > 0 else { throw TemplateError.renderFailed }
            return size.height * (pageWidth / size.width)
        }
    }

    // MARK: - Internals

    private func assetURL(_ ref: TemplateRef) throws -> URL {
        guard store.exists(ref) else { throw TemplateError.missingAsset(ref) }
        return store.fileURL(for: ref)
    }

    private func fillWhite(_ context: CGContext, _ viewport: CGRect) throws {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(viewport)
    }

    /// `CGContext.draw(_:in:)` assumes y-up, so flip back for the duration of the draw.
    private func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// `CGPDFPage.getDrawingTransform` only ever scales *down*, so a planner page smaller than the
    /// canvas would be centred at its original size. We build the fit-to-width transform ourselves,
    /// applying the page's `/Rotate` on the way.
    private func draw(_ page: CGPDFPage, in context: CGContext, pageWidth: CGFloat) {
        let box = PDFSupport.box(of: page)
        let size = PDFSupport.displaySize(of: page)
        guard box.width > 0, box.height > 0, size.width > 0 else { return }
        let scale = pageWidth / size.width
        let drawnHeight = size.height * scale

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: pageWidth, height: drawnHeight))
        // Flip into the PDF's y-up space, with the page box mapped onto the top of the note page.
        context.translateBy(x: 0, y: drawnHeight)
        context.scaleBy(x: 1, y: -1)

        context.scaleBy(x: scale, y: scale)
        switch PDFSupport.rotation(of: page) {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)

        context.drawPDFPage(page)
        context.restoreGState()
    }
}

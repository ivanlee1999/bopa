import NotableKit
import PencilKit
import UIKit

/// A derived document image for covers and sharing. Canvas coordinates are never rewritten:
/// the preserved canvas is one region, followed by the page's ordered flowing content.
enum FlowPagePreview {
    static func ink(page: PageFile, blockID: String, width: CGFloat = 1000) -> UIImage? {
        let ids = FlowText.inkIDs(for: blockID, in: page.blocks)
        let drawing = PencilKitBridge.drawing(from: page.strokes.filter { ids.contains($0.id) })
        let bounds = drawing.bounds
        guard !drawing.strokes.isEmpty, bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(2, width / bounds.width, sqrt(12_000_000 / (bounds.width * bounds.height)))
        guard scale.isFinite, scale > 0 else { return nil }
        return drawing.image(from: bounds, scale: scale)
    }

    static func canvas(page: PageFile, notebookDir: URL, storeRoot: URL) -> UIImage? {
        let claimed = FlowText.inkIDs(in: page.blocks)
        let drawing = PencilKitBridge.drawing(from: page.strokes.filter { !claimed.contains($0.id) })
        let content = PagePreviewRenderer.content(strokes: drawing,
            images: BackgroundRenderer.pageImages(for: page, notebookDir: notebookDir),
            blocks: page.blocks, pageSize: page.pageSize)
        guard let background = BackgroundRenderer.image(for: page, notebookDir: notebookDir, storeRoot: storeRoot)
        else { return content?.image }
        let sheetWidth = max(1, CGFloat(page.pageSize.width)), sheetHeight = max(1, CGFloat(page.pageSize.height))
        let scale = min(1, 1000 / sheetWidth, sqrt(12_000_000 / (sheetWidth * sheetHeight)))
        let width = sheetWidth * scale
        let size = CGSize(width: width, height: sheetHeight * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            background.draw(in: CGRect(x: 0, y: 0, width: width, height: width * background.size.height / background.size.width))
            if let content { content.image.draw(in: CGRect(x: content.frame.minX * scale, y: content.frame.minY * scale, width: content.frame.width * scale, height: content.frame.height * scale)) }
        }
    }

    static func image(page: PageFile, notebookDir: URL, storeRoot: URL,
                      width: CGFloat = 300, maximumHeight: CGFloat = 400) -> UIImage {
        let padding: CGFloat = 16
        let inner = max(1, width - padding * 2)
        let metrics = TextBoxMetrics(body: 17, headingScales: [1.7, 1.4, 1.2],
            padding: 0, listIndent: 22, preferredWidth: inner, minimumWidth: 1, rightMargin: 0)
        var items: [(image: UIImage?, text: String?, frame: CGRect)] = []
        var y = padding
        if let canvas = canvas(page: page, notebookDir: notebookDir, storeRoot: storeRoot) {
            let height = inner * canvas.size.height / max(canvas.size.width, 1)
            items.append((canvas, nil, CGRect(x: padding, y: y, width: inner, height: height)))
            y += height + 20
        }
        for section in FlowText.sections(in: page.blocks) {
            if section.isMarkdown {
                let height = TextBoxLayout.measuredHeight(source: section.source, width: inner, metrics: metrics)
                items.append((nil, section.source, CGRect(x: padding, y: y, width: inner, height: height)))
                y += height + 12
            } else if let block = section.blocks.first {
                var image: UIImage?
                if block.kind == "ink" {
                    image = ink(page: page, blockID: block.id, width: inner)
                } else if block.kind == "image", let asset = block.imageAssetId,
                          let sha = CouchAssetID.sha256Hex(ofAssetID: asset) {
                    image = UIImage(contentsOfFile: notebookDir.appendingPathComponent("images/\(sha)").path)
                }
                if let image {
                    let height = inner * image.size.height / max(image.size.width, 1)
                    items.append((image, nil, CGRect(x: padding, y: y, width: inner, height: height)))
                    y += height + 12
                }
            }
            if y >= maximumHeight { break }
        }
        let size = CGSize(width: width, height: maximumHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.clip(to: CGRect(origin: .zero, size: size))
            for item in items {
                if let image = item.image { image.draw(in: item.frame) }
                if let source = item.text { TextBoxLayout.draw(source: source, in: item.frame, context: context.cgContext, scale: 1, metrics: metrics) }
            }
        }
    }
}

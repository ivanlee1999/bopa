import NotableKit
import SwiftUI
import UIKit
import XCTest
@testable import Bopa

@MainActor
final class TranscriptRenderingTests: XCTestCase {
    private let mixed = """
    # Project

    ## Tasks
    - [x] Done
    - [ ] Next
      - detail
    1. First
    2. Second

    | Item | Qty | Note |
    | :--- | ---: | :---: |
    | Milk | 2 | |
    | A \\| B | 1 | yes |
    """

    func testMixedMarkdownRendersNativelyAtPhoneAndTabletWidthsWithScrollableTables() async throws {
        for width: CGFloat in [375, 834] {
            try await render(TranscriptContent(text: mixed, format: "markdown"), width: width)
        }
    }

    private func render(_ content: TranscriptContent, width: CGFloat) async throws {
        let controller = UIHostingController(rootView: TranscriptReadText(content: content)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.white))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let scrolls = descendants(controller.view).compactMap { $0 as? UIScrollView }
        if content.isMarkdown { XCTAssertFalse(scrolls.isEmpty, "Tables need a native horizontal scroll surface") }
        else { XCTAssertFalse(scrolls.contains { $0.contentSize.width > $0.bounds.width }, "Literal text must not become a table") }
        if content.isMarkdown && width == 375 {
            XCTAssertTrue(scrolls.contains { $0.contentSize.width > $0.bounds.width }, "All table columns must remain reachable on a phone")
            if let table = scrolls.first(where: { $0.contentSize.width > $0.bounds.width }) {
                table.setContentOffset(CGPoint(x: table.contentSize.width - table.bounds.width, y: 0), animated: false)
                XCTAssertGreaterThan(table.contentOffset.x, 0, "Trailing table columns must be reachable")
                table.setContentOffset(.zero, animated: false)
            }
        }
        XCTAssertFalse(descendants(controller.view).contains { $0 is UIButton }, "Task states must be read-only")
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-\(content.isMarkdown ? "markdown" : "literal")-transcript-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
    }

    func testLegacyAndUnknownFormatKeepMarkdownLookingTextLiteral() async throws {
        for format in [nil, "plain", "html", "Markdown"] {
            let content = TranscriptContent(text: mixed, format: format)
            XCTAssertFalse(content.isMarkdown); XCTAssertEqual(content.text, mixed)
            if format == nil || format == "html" { try await render(content, width: 375) }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

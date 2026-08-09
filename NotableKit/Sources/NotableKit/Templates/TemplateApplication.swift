import Foundation

/// What a notebook needs written when it's set up with a template.
public struct NotebookTemplatePlan: Hashable, Sendable {
    /// `defaultBackground` / `defaultBackgroundType` for `manifest.json` — the background new pages
    /// get, on either device.
    public var notebookDefaults: BackgroundFields
    /// Background fields for each page, in page order.
    public var pages: [BackgroundFields]
    /// Asset files that must exist under the notebook's `backgrounds/` collection on the server
    /// before these pages are readable elsewhere.
    public var assets: [TemplateRef]

    public init(notebookDefaults: BackgroundFields, pages: [BackgroundFields], assets: [TemplateRef]) {
        self.notebookDefaults = notebookDefaults
        self.pages = pages
        self.assets = assets
    }
}

/// Turning a chosen `Template` into the background fields that go into page and manifest JSON.
///
/// These are pure functions over the wire format — no I/O — so the page/notebook layer can adopt
/// them as-is and they stay easy to test.
public enum TemplateApplication {
    /// Background fields for a single page.
    public static func pageFields(
        for template: Template,
        pathStyle: BackgroundPathStyle = .relative
    ) -> BackgroundFields {
        template.background.fields(pathStyle: pathStyle)
    }

    /// Background fields for `manifest.json`, so pages created later — including ones created on
    /// the BOOX — start from the same template.
    ///
    /// Notable resolves a notebook default by copying it onto each new page, so a `pdf<N>` default
    /// pins every new page to that one PDF page. That is exactly the "one template, reused forever"
    /// behaviour; it is not page-following (`autoPdf`).
    public static func notebookDefaults(
        for template: Template,
        pathStyle: BackgroundPathStyle = .relative
    ) -> BackgroundFields {
        template.background.fields(pathStyle: pathStyle)
    }

    /// The same template on `count` pages.
    public static func pageFields(
        count: Int,
        from template: Template,
        pathStyle: BackgroundPathStyle = .relative
    ) -> [BackgroundFields] {
        Array(repeating: pageFields(for: template, pathStyle: pathStyle), count: max(0, count))
    }

    /// Everything needed to create a notebook of `pageCount` pages from one template.
    public static func plan(
        pageCount: Int,
        from template: Template,
        pathStyle: BackgroundPathStyle = .relative
    ) -> NotebookTemplatePlan {
        NotebookTemplatePlan(
            notebookDefaults: notebookDefaults(for: template, pathStyle: pathStyle),
            pages: pageFields(count: pageCount, from: template, pathStyle: pathStyle),
            assets: template.ref.map { [$0] } ?? []
        )
    }

    /// A notebook whose pages use different templates — e.g. a cover page plus daily pages, or one
    /// page per page of an imported planner.
    ///
    /// `notebookDefault` names the template new pages should inherit; it defaults to the first one.
    public static func plan(
        pages templates: [Template],
        notebookDefault: Template? = nil,
        pathStyle: BackgroundPathStyle = .relative
    ) -> NotebookTemplatePlan {
        let fallback = notebookDefault ?? templates.first ?? .native(.blank)
        var assets: [TemplateRef] = []
        for ref in templates.compactMap(\.ref) where !assets.contains(ref) {
            assets.append(ref)
        }
        return NotebookTemplatePlan(
            notebookDefaults: notebookDefaults(for: fallback, pathStyle: pathStyle),
            pages: templates.map { pageFields(for: $0, pathStyle: pathStyle) },
            assets: assets
        )
    }

    /// Recover the template a page is already using, so a picker can show the current selection.
    ///
    /// `name` is cosmetic; the page JSON carries no display name.
    public static func template(from fields: BackgroundFields) -> Template? {
        switch PageBackground(fields: fields) {
        case .native(let native):
            return .native(native)
        case .image(let ref):
            return Template(source: .image(ref, repeating: false), name: ref.displayName)
        case .repeatingImage(let ref):
            return Template(source: .image(ref, repeating: true), name: ref.displayName)
        case .pdfPage(let ref, let index):
            return Template(source: .pdf(ref, pageIndex: index), name: "\(ref.displayName) · page \(index + 1)")
        case .coverImage, .autoPDF:
            // Cover art isn't a page template, and autoPdf is a whole-notebook mode Notable's PDF
            // import uses — neither is something this app hands back as a single-page template.
            return nil
        }
    }
}

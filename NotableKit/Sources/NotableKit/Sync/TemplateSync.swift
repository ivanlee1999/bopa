import Foundation

/// Where template assets live on the WebDAV server, and which ones a notebook owes it.
///
/// Assets are stored **per notebook and flat**: `/notable/notebooks/<id>/backgrounds/<fileName>`,
/// even though locally they sit in `pdfs/` or `images/`. A template shared by two notebooks is
/// uploaded once per notebook — that is Notable's layout, not a choice this app makes.
///
/// Interop caveat (Notable v0.2.6): Notable's own picker records an absolute device path in
/// `background`, and its uploader skips any background whose path is absolute — so templates
/// imported *on the BOOX* never reach the server. Its downloader, meanwhile, resolves the field as
/// a store-relative path. We therefore always write relative paths (`BackgroundPathStyle.relative`)
/// and upload the asset ourselves: that is the form Notable's download path understands. See
/// `docs/notable-sync-protocol.md` §7.
public enum TemplateSync {
    public static let defaultRoot = "/notable"

    public static func backgroundsDirectory(notebookId: String, root: String = defaultRoot) -> String {
        "\(root)/notebooks/\(notebookId)/backgrounds"
    }

    public static func remotePath(
        notebookId: String,
        ref: TemplateRef,
        root: String = defaultRoot
    ) -> String {
        "\(backgroundsDirectory(notebookId: notebookId, root: root))/\(ref.remoteName)"
    }

    /// Assets referenced by a notebook's pages, deduplicated, in first-seen order — the upload set.
    public static func assets(in backgrounds: [PageBackground]) -> [TemplateRef] {
        var refs: [TemplateRef] = []
        for ref in backgrounds.compactMap(\.templateRef) where !refs.contains(ref) {
            refs.append(ref)
        }
        return refs
    }

    /// Same, straight from page JSON fields.
    public static func assets(in fields: [BackgroundFields]) -> [TemplateRef] {
        assets(in: fields.map(PageBackground.init(fields:)))
    }

    /// Of those assets, the ones this device doesn't have yet — the download set.
    public static func missingLocally(_ refs: [TemplateRef], store: TemplateStore) -> [TemplateRef] {
        refs.filter { !store.exists($0) }
    }

    /// Which local folder a downloaded asset belongs in. The server name is flat, so the folder
    /// comes from the referencing page's background type — pass it when you have it, otherwise the
    /// extension is a good guess.
    public static func folder(forRemoteName name: String, referencedAs background: PageBackground? = nil) -> TemplateFolder {
        if let folder = background?.templateRef?.folder { return folder }
        return TemplateStore.folder(forFileExtension: (name as NSString).pathExtension) ?? .images
    }
}

import Foundation

/// Converts between what bopa keeps on disk and what goes into CouchDB.
///
/// The two are deliberately near-identical — the CouchDB document is the on-disk file plus the
/// merge's bookkeeping (`updatedBy`, tombstones) and minus what is device-local (`scroll`,
/// `openPageId`, `linkedExternalUri`). Keeping the shapes aligned means sync never has to
/// reinterpret ink, only move it.
public enum CouchMapping {

    // MARK: Page

    /// `notebookDir` is where this page's images live. It is needed because an image travels as a
    /// content-addressed `asset:` reference while it is stored as a path, and only the file itself
    /// can say which asset it is.
    public static func couchPage(
        from file: PageFile, deviceID: String, notebookDir: URL
    ) -> CouchPage {
        CouchPage(
            notebookId: file.notebookId,
            title: file.title,
            background: file.background,
            backgroundType: file.backgroundType,
            strokes: file.strokes.map { couchStroke(from: $0, deviceID: deviceID) },
            deletedStrokes: file.deletedStrokes,
            images: file.images.map { couchImage(from: $0, notebookDir: notebookDir) },
            deletedImages: [],
            createdAt: file.createdAt,
            updatedAt: file.updatedAt,
            updatedBy: file.updatedBy.isEmpty ? deviceID : file.updatedBy)
    }

    /// Rebuilds the on-disk page. `scroll` is device-local and does not travel, so it is carried
    /// over from the copy already on disk rather than reset — otherwise every incoming change
    /// would scroll the reader back to the top.
    /// - Parameter keeping: strokes already on disk that the merge never saw, appended after the
    ///   merged ink. They are the newest thing on the page, so last — which is also topmost — is
    ///   where they belong. See `FileCouchStore.survivingStrokes`.
    public static func pageFile(
        from page: CouchPage, id: String, existing: PageFile?, notebookDir: URL,
        keeping surviving: [StrokeDTO] = []
    ) -> PageFile {
        let existingImages = Dictionary(
            (existing?.images ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // What this page already draws, indexed by content. An image arriving from the peer names
        // bytes, not a filename, so if those bytes are already here — under whatever name they
        // were imported with — the reference points at the file that has them rather than at one
        // nothing will ever write.
        var held: [String: String] = [:]
        for image in existing?.images ?? [] {
            guard let uri = image.uri,
                  let assetID = NotableImageFiles.assetID(forURI: uri, notebookDir: notebookDir)
            else { continue }
            held[assetID] = uri
        }
        return PageFile(
            id: id,
            notebookId: page.notebookId,
            title: page.title,
            background: page.background,
            backgroundType: page.backgroundType,
            parentFolderId: existing?.parentFolderId,
            scroll: existing?.scroll ?? 0,
            createdAt: page.createdAt,
            updatedAt: page.updatedAt,
            strokes: page.strokes.map(strokeDTO(from:)) + surviving,
            images: page.images.map {
                imageDTO(
                    from: $0, existing: existingImages[$0.id],
                    heldAt: $0.assetId.flatMap { held[$0] })
            },
            deletedStrokes: page.deletedStrokes,
            updatedBy: page.updatedBy)
    }

    static func couchStroke(from dto: StrokeDTO, deviceID: String) -> CouchStroke {
        CouchStroke(
            id: dto.id, createdAt: dto.createdAt, updatedAt: dto.updatedAt, deviceId: deviceID,
            pen: dto.pen, color: dto.color, size: dto.size, maxPressure: dto.maxPressure,
            top: dto.top, bottom: dto.bottom, left: dto.left, right: dto.right,
            pointsData: dto.pointsData)
    }

    static func strokeDTO(from stroke: CouchStroke) -> StrokeDTO {
        var dto = StrokeDTO(
            id: stroke.id, size: stroke.size,
            pen: NotablePen(rawValue: stroke.pen) ?? .ballpen,
            color: stroke.color, maxPressure: stroke.maxPressure,
            top: stroke.top, bottom: stroke.bottom, left: stroke.left, right: stroke.right,
            pointsData: stroke.pointsData,
            createdAt: stroke.createdAt, updatedAt: stroke.updatedAt)
        // An unrecognized pen name must survive the round trip rather than silently become a
        // ballpen — the peer may simply be a newer build with a pen this one has not learned.
        dto.pen = stroke.pen
        return dto
    }

    static func couchImage(from dto: ImageDTO, notebookDir: URL) -> CouchImage {
        CouchImage(
            id: dto.id,
            assetId: NotableImageFiles.assetID(forURI: dto.uri, notebookDir: notebookDir),
            x: dto.x, y: dto.y,
            width: dto.width, height: dto.height,
            createdAt: dto.createdAt, updatedAt: dto.updatedAt)
    }

    /// The local file an incoming image should be drawn from. `heldAt` is where this device
    /// already keeps those exact bytes, if it does.
    ///
    /// A file already here keeps its name — that is the image the user imported over WebDAV, or
    /// placed on this device, and renaming it to its hash would orphan it for the other backend.
    /// Anything else is filed under the hash, which is where the downloader will put the bytes.
    static func imageDTO(from image: CouchImage, existing: ImageDTO?, heldAt: String?) -> ImageDTO {
        let uri: String?
        if let assetID = image.assetId, CouchAssetID.sha256Hex(ofAssetID: assetID) != nil {
            uri = heldAt ?? NotableImageFiles.localURI(forAssetID: assetID)
        } else {
            // The peer named no asset — it has not hashed its copy, or the document predates
            // assets travelling at all. That says nothing about the file this device holds, so
            // whatever is here keeps its place rather than being forgotten.
            //
            // What is *not* kept is the peer's own `assetId` text. Before assets travelled it held
            // the writer's local path, which never named anything here; adopting it now would let
            // a document decide which file this device reads.
            uri = existing?.uri
        }
        return ImageDTO(
            id: image.id, x: image.x, y: image.y, width: image.width, height: image.height,
            uri: uri, createdAt: image.createdAt, updatedAt: image.updatedAt)
    }

    // MARK: Notebook

    public static func couchNotebook(
        from manifest: NotebookManifest, deviceID: String
    ) -> CouchNotebook {
        CouchNotebook(
            title: manifest.title,
            pageIds: manifest.pageIds,
            deletedPageIds: manifest.deletedPageIds,
            parentFolderId: manifest.parentFolderId,
            defaultBackground: manifest.defaultBackground,
            defaultBackgroundType: manifest.defaultBackgroundType,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            updatedBy: manifest.updatedBy.isEmpty ? deviceID : manifest.updatedBy)
    }

    /// `openPageId` and `linkedExternalUri` stay device-local: which page you had open on the iPad
    /// is not a fact about the notebook, and the BOOX's linked path does not exist here.
    public static func manifest(
        from notebook: CouchNotebook, id: String, existing: NotebookManifest?
    ) -> NotebookManifest {
        NotebookManifest(
            notebookId: id,
            title: notebook.title,
            pageIds: notebook.pageIds,
            openPageId: existing?.openPageId,
            parentFolderId: notebook.parentFolderId,
            defaultBackground: notebook.defaultBackground,
            defaultBackgroundType: notebook.defaultBackgroundType,
            linkedExternalUri: existing?.linkedExternalUri,
            createdAt: notebook.createdAt,
            updatedAt: notebook.updatedAt,
            serverTimestamp: notebook.updatedAt,
            deletedPageIds: notebook.deletedPageIds,
            updatedBy: notebook.updatedBy)
    }

    // MARK: Folder

    public static func couchFolder(from dto: FolderDTO, deviceID: String) -> CouchFolder {
        CouchFolder(
            title: dto.title, parentFolderId: dto.parentFolderId,
            createdAt: dto.createdAt, updatedAt: dto.updatedAt, updatedBy: deviceID)
    }

    public static func folderDTO(from folder: CouchFolder, id: String) -> FolderDTO {
        FolderDTO(
            id: id, title: folder.title, parentFolderId: folder.parentFolderId,
            createdAt: folder.createdAt, updatedAt: folder.updatedAt)
    }
}

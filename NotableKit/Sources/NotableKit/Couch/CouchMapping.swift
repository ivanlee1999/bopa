import Foundation

/// Converts between what bopa keeps on disk and what goes into CouchDB.
///
/// The two are deliberately near-identical — the CouchDB document is the on-disk file plus the
/// merge's bookkeeping (`updatedBy`, tombstones) and minus what is device-local (`scroll`,
/// `openPageId`, `linkedExternalUri`). Keeping the shapes aligned means sync never has to
/// reinterpret ink, only move it.
public enum CouchMapping {

    // MARK: Page

    public static func couchPage(from file: PageFile, deviceID: String) -> CouchPage {
        CouchPage(
            notebookId: file.notebookId,
            background: file.background,
            backgroundType: file.backgroundType,
            strokes: file.strokes.map { couchStroke(from: $0, deviceID: deviceID) },
            deletedStrokes: file.deletedStrokes,
            images: file.images.map(couchImage(from:)),
            deletedImages: [],
            createdAt: file.createdAt,
            updatedAt: file.updatedAt,
            updatedBy: file.updatedBy.isEmpty ? deviceID : file.updatedBy)
    }

    /// Rebuilds the on-disk page. `scroll` is device-local and does not travel, so it is carried
    /// over from the copy already on disk rather than reset — otherwise every incoming change
    /// would scroll the reader back to the top.
    public static func pageFile(from page: CouchPage, id: String, existing: PageFile?) -> PageFile {
        PageFile(
            id: id,
            notebookId: page.notebookId,
            background: page.background,
            backgroundType: page.backgroundType,
            parentFolderId: existing?.parentFolderId,
            scroll: existing?.scroll ?? 0,
            createdAt: page.createdAt,
            updatedAt: page.updatedAt,
            strokes: page.strokes.map(strokeDTO(from:)),
            images: page.images.map(imageDTO(from:)),
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

    static func couchImage(from dto: ImageDTO) -> CouchImage {
        CouchImage(
            id: dto.id, assetId: dto.uri, x: dto.x, y: dto.y,
            width: dto.width, height: dto.height,
            createdAt: dto.createdAt, updatedAt: dto.updatedAt)
    }

    static func imageDTO(from image: CouchImage) -> ImageDTO {
        ImageDTO(
            id: image.id, x: image.x, y: image.y, width: image.width, height: image.height,
            uri: image.assetId, createdAt: image.createdAt, updatedAt: image.updatedAt)
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

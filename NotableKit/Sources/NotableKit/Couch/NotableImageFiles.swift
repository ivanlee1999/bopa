import Foundation

/// Where a page's images live on this device, and how a local file relates to the `asset:<sha256>`
/// document that carries it between devices.
///
/// One place, because two things have to agree about it: the renderer, which turns an `ImageDTO`'s
/// `uri` into a file to draw, and sync, which turns that same file into a content-addressed id and
/// back. A second copy of the rule would show up as an image that syncs but does not appear.
public enum NotableImageFiles {
    /// Both apps keep page images in a folder of this name, and the WebDAV layout mirrors it.
    public static let directoryName = "images"

    public static func directory(in notebookDir: URL) -> URL {
        notebookDir.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Resolves an `ImageDTO` uri to a file under the notebook's `images/`.
    ///
    /// Only the name is used, never the path around it. A device-absolute Android path — which
    /// pages written on the BOOX carry — has no meaning here beyond its last component, and a
    /// relative uri is deliberately treated the same way: the uri arrives inside a document
    /// another device wrote, so `images/../manifest.json` would otherwise be a way for a peer to
    /// aim a read or a download at a file that is not an image. Every real uri is already
    /// `images/<name>`, so nothing legitimate resolves differently.
    public static func url(uri: String?, notebookDir: URL) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        let basename = (uri as NSString).lastPathComponent
        guard !basename.isEmpty, basename != "/", basename != ".", basename != ".."
        else { return nil }
        return directory(in: notebookDir).appendingPathComponent(basename)
    }

    /// The uri to store for an asset this device is about to hold: the hash itself, no extension.
    ///
    /// Naming the file after its content is what lets the asset id be recovered from the uri alone
    /// (see `assetID(forURI:notebookDir:)`), which matters in the window between a page arriving
    /// and its images being downloaded — the page has to be pushable in that window without
    /// dropping references to bytes that are still on their way.
    public static func localURI(forAssetID assetID: String) -> String? {
        guard let sha = CouchAssetID.sha256Hex(ofAssetID: assetID) else { return nil }
        return "\(directoryName)/\(sha)"
    }

    /// The asset document a placed image belongs to.
    ///
    /// The bytes decide when they are here; the filename decides when they are not yet. An image
    /// whose file is missing and whose name says nothing about its content is genuinely unknown —
    /// nil, rather than a guess that would travel as a reference to bytes nobody has.
    public static func assetID(
        forURI uri: String?, notebookDir: URL, sha256: (URL) -> String? = CouchAssetID.sha256Hex
    ) -> String? {
        guard let url = url(uri: uri, notebookDir: notebookDir) else { return nil }
        if let sha = sha256(url) { return CouchDocID.asset(sha) }
        let basename = url.lastPathComponent
        return CouchAssetID.isSHA256Hex(basename) ? CouchDocID.asset(basename) : nil
    }
}

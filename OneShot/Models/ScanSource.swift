import Foundation

/// A folder the user has picked, and the name to show for it.
struct FolderSelection: Equatable, Sendable, Hashable {
    let url: URL
    let name: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
    }
}

/// Where a scan reads its items from.
///
/// The photo library is the default, and the only source that needs a permission
/// prompt. A folder is anything the Files app can reach — on-device storage, iCloud
/// Drive, a shared folder, or a USB drive or SD card plugged into the device. iOS
/// exposes all of those through the same document picker, so one mechanism covers
/// what would be several on a desktop.
enum ScanSource: Equatable, Sendable {
    case photoLibrary
    case folder(FolderSelection)

    var title: String {
        switch self {
        case .photoLibrary: "Photo Library"
        case .folder(let selection): selection.name
        }
    }

    var symbolName: String {
        switch self {
        case .photoLibrary: "photo.on.rectangle.angled"
        case .folder: "folder"
        }
    }

    /// Only the photo library goes through PhotoKit, so only it needs the prompt.
    /// A folder the user picked themselves is already permission enough.
    var needsPhotoAccess: Bool {
        if case .photoLibrary = self { return true }
        return false
    }

    var scanButtonTitle: String {
        switch self {
        case .photoLibrary: "Scan Library"
        case .folder: "Scan Folder"
        }
    }

    var subtitle: String {
        switch self {
        case .photoLibrary:
            "OneShot reads every photo and video on this device, groups the copies together and picks the best one from each group."
        case .folder(let selection):
            "OneShot reads the photos and videos in \(selection.name), including anything in folders inside it."
        }
    }
}

/// Keeps a picked folder reachable across launches.
///
/// A folder chosen from the Files app is only readable while the app holds a
/// security-scoped bookmark for it and has that scope open. The bookmark is stored so
/// the choice survives a relaunch; the scope is opened when the folder becomes the
/// active source and closed when it stops being one, because iOS caps how many an app
/// may hold open at once.
@MainActor
enum FolderAccess {
    private static let bookmarkKey = "OneShot.folderBookmark"
    private static var open: URL?

    /// Opens the security scope for `url` and remembers it for next launch.
    /// Returns false when the folder cannot be reached, so the caller can fall back
    /// rather than starting a scan that would find nothing.
    @discardableResult
    static func begin(_ url: URL) -> Bool {
        end()
        guard url.startAccessingSecurityScopedResource() else { return false }
        open = url
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        return true
    }

    static func end() {
        open?.stopAccessingSecurityScopedResource()
        open = nil
    }

    /// The folder from a previous launch, with its scope reopened.
    static func restore() -> FolderSelection? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            forget()
            return nil
        }
        // A stale bookmark still resolves; re-saving it here keeps it working rather
        // than letting it decay until the folder silently stops being readable.
        guard begin(url) else {
            forget()
            return nil
        }
        return FolderSelection(url: url)
    }

    static func forget() {
        end()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
}

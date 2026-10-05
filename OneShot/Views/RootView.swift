import SwiftUI

struct RootView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // The prompt is only a gate for the photo library. A folder the user
            // picked themselves is its own permission, so scanning one should not
            // require handing over the whole photo library first.
            if !library.source.needsPhotoAccess || library.hasFullAccess {
                ScanFlowView()
            } else {
                PermissionView()
            }
        }
        .animation(.smooth(duration: 0.35), value: library.authorization)
        .task { library.restoreSource() }
        .onChange(of: scenePhase) { _, newValue in
            // Access can be granted or revoked in Settings while the app is
            // backgrounded, so re-read it every time we come forward.
            if newValue == .active {
                library.refreshAuthorization()
            }
        }
    }
}

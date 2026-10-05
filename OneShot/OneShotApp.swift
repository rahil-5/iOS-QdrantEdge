import SwiftUI

@main
struct OneShotApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .tint(Color.accentColor)
        }
    }
}

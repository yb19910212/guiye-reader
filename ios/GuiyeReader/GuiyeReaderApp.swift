import SwiftUI

@main
struct GuiyeReaderApp: App {
    @StateObject private var theme = ThemeStore()
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(theme)
                .tint(theme.palette.accent)
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}

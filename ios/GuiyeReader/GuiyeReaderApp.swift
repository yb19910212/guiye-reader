import SwiftUI

@main
struct GuiyeReaderApp: App {
    @UIApplicationDelegateAdaptor(GuiyeReaderAppDelegate.self) private var appDelegate
    @StateObject private var theme = ThemeStore()
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(theme)
                .tint(theme.palette.accent)
                .preferredColorScheme(theme.preferredColorScheme)
                .task { await ReadingReminderScheduler.shared.refreshIfEnabled() }
        }
    }
}

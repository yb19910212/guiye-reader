import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case paper, sepia, forest, night
    var id: String { rawValue }
    var title: String {
        switch self {
        case .paper: return "纸张"
        case .sepia: return "暖棕"
        case .forest: return "森林"
        case .night: return "夜间"
        }
    }
    var icon: String {
        switch self {
        case .paper: return "doc.plaintext"
        case .sepia: return "sun.haze"
        case .forest: return "leaf"
        case .night: return "moon.stars"
        }
    }
}

struct AppPalette {
    let background: Color
    let surface: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let highlight: Color
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var selection: AppTheme {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: "app.theme") }
    }

    init() {
        selection = AppTheme(rawValue: UserDefaults.standard.string(forKey: "app.theme") ?? "") ?? .paper
    }

    var preferredColorScheme: ColorScheme? { selection == .night ? .dark : .light }
    var palette: AppPalette {
        switch selection {
        case .paper:
            return AppPalette(background: Color(red: 0.965, green: 0.953, blue: 0.918), surface: .white.opacity(0.72), text: Color(red: 0.118, green: 0.169, blue: 0.141), secondary: .secondary, accent: Color(red: 0.192, green: 0.373, blue: 0.286), highlight: Color(red: 0.89, green: 0.93, blue: 0.87))
        case .sepia:
            return AppPalette(background: Color(red: 0.91, green: 0.84, blue: 0.70), surface: Color(red: 0.98, green: 0.92, blue: 0.80), text: Color(red: 0.24, green: 0.15, blue: 0.09), secondary: Color(red: 0.42, green: 0.30, blue: 0.20), accent: Color(red: 0.55, green: 0.30, blue: 0.12), highlight: Color(red: 0.83, green: 0.69, blue: 0.46))
        case .forest:
            return AppPalette(background: Color(red: 0.83, green: 0.88, blue: 0.80), surface: Color(red: 0.91, green: 0.94, blue: 0.88), text: Color(red: 0.08, green: 0.18, blue: 0.12), secondary: Color(red: 0.23, green: 0.36, blue: 0.27), accent: Color(red: 0.10, green: 0.34, blue: 0.22), highlight: Color(red: 0.66, green: 0.78, blue: 0.65))
        case .night:
            return AppPalette(background: Color(red: 0.055, green: 0.075, blue: 0.065), surface: Color(red: 0.10, green: 0.13, blue: 0.11), text: Color(red: 0.88, green: 0.90, blue: 0.84), secondary: Color(red: 0.60, green: 0.65, blue: 0.60), accent: Color(red: 0.86, green: 0.62, blue: 0.20), highlight: Color(red: 0.20, green: 0.28, blue: 0.21))
        }
    }
}

struct ThemeSettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(AppTheme.allCases) { option in
                Button { theme.selection = option } label: {
                    HStack {
                        Label(option.title, systemImage: option.icon)
                        Spacer()
                        if theme.selection == option { Image(systemName: "checkmark.circle.fill") }
                    }
                }
            }
            .navigationTitle("外观主题")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(theme.palette.accent)
        .preferredColorScheme(theme.preferredColorScheme)
    }
}

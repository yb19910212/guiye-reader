import SwiftUI

struct AISettingsView: View {
    @AppStorage("ai.enabled") private var enabled = false
    @AppStorage("ai.provider") private var provider = "OpenAI"
    @AppStorage("ai.model") private var model = "gpt-5.6-sol"
    @AppStorage("ai.currentBookOnly") private var currentBookOnly = true
    @AppStorage("ai.noSpoilers") private var noSpoilers = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 阅读助手", isOn: $enabled)
                    Picker("模型提供方", selection: $provider) {
                        Text("OpenAI").tag("OpenAI")
                        Text("本地模型").tag("Local")
                        Text("自定义兼容服务").tag("Custom")
                    }
                    TextField("模型", text: $model)
                } header: { Text("模型") } footer: { Text("应用不会内置或上传你的服务密钥；正式云模型连接应通过你控制的后端签发短期令牌。") }
                Section("隐私边界") {
                    Toggle("仅允许当前书籍", isOn: $currentBookOnly)
                    Toggle("小说禁止剧透", isOn: $noSpoilers)
                    Label("AI 关闭时，导入、阅读、笔记与导出仍完整可用", systemImage: "lock.shield")
                }
                Section("计划能力") {
                    Label("选中文字：解释、翻译、简化", systemImage: "text.magnifyingglass")
                    Label("章节摘要与带页码来源的问答", systemImage: "quote.bubble")
                    Label("高亮转卡片和复习题", systemImage: "rectangle.stack")
                }
            }
            .navigationTitle("AI 阅读助手")
        }
    }
}

# 归页（Guiye Reader）

本地优先、跨平台、帮助用户读完并沉淀知识的个人阅读中心。

## 当前里程碑

仓库目前提供 iOS 与 Android 原生应用骨架，以及第二阶段的“真实文件导入 + 阅读 + AI 语音”体验：

- 系统文件选择器批量导入 EPUB、PDF、TXT
- 文件复制到应用私有书库、SHA-256 去重和本地 JSON 索引
- TXT 真实正文阅读与逐段朗读
- EPUB/PDF 安全入库和 Readium 阅读器路由
- 章节正文阅读页
- 自动识别段落语言
- 系统离线语音朗读
- 音色、语言、语速选择
- 播放、暂停、继续、上一段、下一段
- 当前朗读段落高亮
- 可插拔 `SpeechEngine` 接口，为云端神经语音和本地模型预留扩展点

Readium 依赖已经固定到 Android 3.3、iOS 3.9 系列。EPUB/PDF 完整导航器、笔记和同步将按 `docs/ROADMAP.md` 继续实现。

## 项目结构

```text
android/       Kotlin + Jetpack Compose
ios/           SwiftUI + AVFoundation
docs/          架构、语音方案、路线图
.github/       双端持续集成
```

## Android

要求 Android Studio、JDK 17、Android SDK 35。打开 `android` 目录并运行 `app`。

## iOS

要求 Xcode 16 或更新版本。打开 `ios/GuiyeReader.xcodeproj`，选择模拟器运行。最低系统版本为 iOS 17。

## 隐私原则

- 默认使用系统离线语音，正文不离开设备。
- 云端语音必须由用户主动启用，并明确显示将上传的章节范围。
- 任何语音缓存都可以单独清理，不影响原始书籍和笔记。
- 不提供 DRM 破解能力。

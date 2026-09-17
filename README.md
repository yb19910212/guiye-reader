# 归页（Guiye Reader）

本地优先、跨平台、帮助用户读完并沉淀知识的个人阅读中心。

## 当前里程碑

仓库目前提供 iOS 与 Android 原生应用，以及可直接安装验证的本地优先阅读闭环：

- 系统文件选择器批量导入 EPUB、PDF、TXT
- 文件复制到应用私有书库、SHA-256 去重和本地 JSON 索引
- TXT 章节识别、正文搜索、排版调节和稳定进度保存
- EPUB 重排阅读与 PDF 翻页阅读
- 书签、高亮、带标签笔记、全库检索和 Markdown 导出
- Kokoro INT8 中英双语端侧神经语音，内置 4 款中文女声与 2 款英语女声
- iOS 实验版：Qwen 0.6B Base 4bit，保留用户选定的 1号/4号合成参考音色；Android 暂不接入 Qwen
- 有界语音预生成、长段切分、旧回调过滤和切换/语速防抖（真机压力验收待完成）
- 系统本地语音朗读、语言自动匹配、音色筛选和试听
- 阅读统计、连续阅读目标和单本书完成计划
- OPDS、WebDAV 与系统 SMB 文件提供器导入
- 完整备份与增量恢复（书库元数据、进度、笔记、统计和计划）
- 本地每日阅读提醒，可设置时间并随时关闭

核心阅读、Kokoro 神经语音和提醒均可离线使用；书籍正文与语音合成不会离开设备。后续能力按 `docs/ROADMAP.md` 继续实现。

## 项目结构

```text
android/       Kotlin + Jetpack Compose
ios/           SwiftUI + AVFoundation
docs/          架构、语音方案、路线图
.github/       双端持续集成
```

## Android

要求 Android Studio、JDK 17、Android SDK 36。打开 `android` 目录并运行 `app`。正式 Release 会内置离线模型；源码本地构建前请按 `docs/OFFLINE_TTS.md` 准备模型资源。

## iOS

要求 Xcode 16.4 或更新版本。打开 `ios/GuiyeReader.xcodeproj`。本实验版最低系统版本为 iOS 18，Qwen 应在支持 Metal 的真机验证，不能用模拟器通过代替真机测试。完整预发布包内置两种离线模型；源码本地构建前请按 `docs/OFFLINE_TTS.md` 准备 Kokoro，并运行 `python3 scripts/prepare_qwen_model.py ios/GuiyeReader/QwenModel` 准备 Qwen。

Qwen 参考音色不保证与电脑上的 1.7B VoiceDesign 试听完全相同。模型、原始参考音频和正文合成都在本机，不依赖在线接口。稳定性修改与待验证项见 `docs/VOICE_STABILITY.md`。

## 隐私原则

- 系统语音与 Kokoro 神经语音均在设备本地运行，正文不离开设备。
- App 不调用公共 TTS 接口，也不需要语音服务账号或 API Key。
- 任何语音缓存都可以单独清理，不影响原始书籍和笔记。
- 不提供 DRM 破解能力。

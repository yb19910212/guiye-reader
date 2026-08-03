# 技术架构

## 总体原则

双端采用原生 UI 和原生生命周期，领域模型保持一致。阅读、语音、笔记和同步通过接口隔离，避免 UI 直接依赖具体引擎。

## 分层

1. Presentation：SwiftUI / Jetpack Compose 页面与状态。
2. Application：阅读会话、语音队列、导入任务等用例。
3. Domain：Publication、Locator、Annotation、SpeechVoice、SpeechSegment。
4. Infrastructure：Readium、PDF 内核、SQLite、系统语音、云端语音、文件系统。

## 关键接口

- `SpeechEngine`：查询语言/音色，播放分段，暂停、继续、停止和跳转。
- `PublicationRepository`：导入、读取、删除与全文索引。
- `ReadingProgressRepository`：以稳定 Locator 保存进度。
- `AnnotationRepository`：高亮、批注和书签。
- `SyncService`：本地事件日志和可选云同步。

## 语音数据流

正文解析 → 分段与语言识别 → 语音队列 → 引擎合成/播放 → 段落回调 → 阅读页高亮 → Locator 持久化。

云端引擎只接收用户明确授权的分段，不得默认上传整本书。缓存以书籍指纹、音色、语速和文本摘要作为键。

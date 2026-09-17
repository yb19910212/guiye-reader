# v0.14.0 / Build 51 实验预发布

- iOS 18+ 新增 1号「温柔自然」、4号「温柔微嗲」。内置 Qwen 0.6B Base 4bit 与选定参考音频，可以生成新正文，不是循环播放试听。
- 原有 Kokoro 与系统音色保留；Android 本版优化原引擎，新 Qwen 音色后续跟进。
- 双端增加有限预生成、长段切分、过期任务/回调过滤和语速切换防抖，降低段间等待和切换风险。
- Qwen 实验版仅限前台朗读，离开前台会停止；锁屏听书请使用原有音色。
- 模型随安装包提供，正文不上传，运行时无需下载模型。完整 IPA 约 1.63 GB，APK 约 338 MB。
- 手机量化模型与桌面试听模型不同，音色相似度和生成速度尚需真机验收。预生成不能保证在慢于实时的推理速度下完全消除停顿。

## 下载与签名

- [iOS 未签名 IPA](https://github.com/yb19910212/guiye-reader/releases/download/build-51/GuiyeReader-unsigned.ipa)：需要自行签名。
- [Android APK](https://github.com/yb19910212/guiye-reader/releases/download/build-51/GuiyeReader-android.apk)：开发签名安装包。
- [预发布页面](https://github.com/yb19910212/guiye-reader/releases/tag/build-51)，原稳定版本未删除。

## 验证边界

[流水线 35173486387](https://github.com/yb19910212/guiye-reader/actions/runs/35173486387) 已通过 Android 测试/编译、Kokoro 实际合成、iOS TXT/语音队列检查、iOS 编译、包内模型和参考音频检查以及发布。源代码提交：`03e00083a2da58d1e4e304b416582cd09f64d5ce`。

尚未取得 iPhone 17 Pro Max 的崩溃日志，未完成真机快速切换、持续30分钟听书、内存/发热和音质验收；不宣称全部闪退和停顿已消除。

模型来源：Kokoro / sherpa-onnx、Qwen / MLX 社区量化模型（Apache-2.0）；Swift 接入来源与修改见 vendor/Qwen3TTS/NOTICE.md。

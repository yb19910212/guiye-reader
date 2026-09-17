# 离线神经语音

归页 v0.13.0 使用 `sherpa-onnx 1.13.8` 在设备端运行 `kokoro-int8-multi-lang-v1_1`。模型支持中文和英语，共 103 个说话人；当前界面精选 4 个中文女声和 2 个英语女声。朗读时只处理当前段落，不上传正文，也不依赖网络服务。

## 安装包策略

- 发布版 APK 与未签名 IPA 直接内置 INT8 模型，安装后即可离线使用。
- 模型压缩包约 140 MB，解压后再加双端推理库，因此安装包会比上一版明显增大。
- 模型只在首次选择 Kokoro 音色时加载；系统语音仍是轻量回退方案。
- 段落逐个合成，退出阅读或切换音色时会丢弃过期任务，避免播放旧内容。

## 本地源码构建

模型源地址：

`https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2`

下载后核对 SHA-256：

`a1e94694776049035c4f2c6529f003aaece993c76aae9a78995831c3c4dcafc6`

将完整模型目录放到：

- Android：`android/app/src/main/assets/kokoro-int8-multi-lang-v1_1/`
- iOS：把目录内的文件放到 `ios/GuiyeReader/KokoroModel/`

GitHub Actions 的版本标签构建会自动完成下载、校验和打包；普通拉取请求只做代码编译检查，不生成可用于离线朗读的发布包。

## 开源许可

- sherpa-onnx：Apache License 2.0
- Kokoro 模型权重：Apache License 2.0

模型包内保留上游 `LICENSE` 文件。发布时应同时保留仓库中的第三方许可说明。

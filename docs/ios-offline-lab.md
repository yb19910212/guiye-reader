# iOS offline voice lab

## v0.17.2 complete bundled edition
- Published: https://github.com/yb19910212/guiye-reader/releases/tag/ios-lab-4
  from `f1c7443de77100e8c9df7f2bdcdeef9ca1bfc243`; Actions `35226756816` succeeded.
  Final Release IPA downloaded and revalidated locally: 1,471,196,365 bytes,
  SHA256 `6d0d155a03fb96bba8e80eaaa62ed4c35bfea915029321e62d2059ce47ded322`
  matches GitHub's asset digest. Both packaged weight hashes match pinned upstream.
  Swift tokenizer parity, model-file regression and reader regression checks passed.
  Only Release storage is used for the large binary (no duplicate Actions artifact).
  No physical iPhone runtime acceptance was performed.
- Both pinned MLX weights (~1.7 GB uncompressed), converted tokenizer/configs,
  original 1/4 reference recordings, model attribution and Apache-2.0 license are
  bundled inside the IPA. Standard Android/lite builds remain unchanged.
- The complete workflow removes `--support-only`; the generated manifest has no
  remote-file URLs. Build downloads verify the existing pinned weight hashes.
- The lab verifies all bundled files off MainActor, before any URLSession or
  writable model directory is created. It loads weights directly from QwenSupport
  in the app bundle and does not duplicate them under Application Support.
- Downloads/import UI is hidden in the full edition. Start with "校验内置模型",
  then test voice 1/4 offline. No automatic model loading on library startup.
- Final IPA validation streams SHA256 over all packaged resources, including both
  weights, and checks version 0.17.2/build 24. Device inference remains unverified;
  bundling fixes delivery, not model speed or OS memory limits.

## v0.17.1 model import and source selection
- Published as https://github.com/yb19910212/guiye-reader/releases/tag/ios-lab-2
  from `37a660e7b7cef7b73fc25e323fedc37b2252386b`; Actions `35224102009` succeeded.
  Actual downloaded IPA v0.17.1 (23), 19,172,665 bytes, revalidated with
  `verify_qwen_lab.py`; SHA256 matches GitHub:
  `f1199b4f8799f29924f05320d5e497bb536ba9ae4376394c0c6581b4d873473f`.
  Import/source, tokenizer parity and existing reader regression tests passed.
  HF Mirror main-weight HEAD/redirect returned HTTP 200 from this workstation;
  phone-network downloads and Files-provider UI remain unverified on a device.
- Select official Hugging Face, explicitly opt into third-party HF Mirror, or enter
  an HTTPS model-root directory. No silent switch to third-party hosts. Custom
  roots reject URL credentials/query strings/fragments and are not TTS API URLs.
- The chosen root must expose `model.safetensors` (1,024,490,700 bytes) and
  `speech_tokenizer/model.safetensors` (682,293,092 bytes), matching pinned hashes.
- Alternatively download these two files in a browser/on a computer, transfer to
  Files, and use the two separately labelled import buttons. They share a basename;
  choose the right role. ZIP import is not supported. Configs and the repaired
  tokenizer are supplied by the app, not imported from arbitrary model folders.
- Copy/hash in 4 MB blocks off MainActor into staging, replace only on correct
  SHA256, clean staging on cancellation/failure. Preserve old valid target on bad
  imports. Coordinated/security-scoped reading supports Files providers; cloud
  providers may still need network to materialize a selected file.
- Explicit cellular/expensive-network eligibility; device policy still applies.
  30-second inactivity timeout, 2-hour resource limit, up to two attempts for select
  transient network failures. Completed valid files are reused; partial individual
  file downloads do NOT yet resume. Remain in foreground.
- Status differentiates download/import/test, connection, bytes, and installation.
  Successful first import may say another file is still missing; it is retained.
- Existing reader/API/Android behavior unchanged. File helper smoke tests cover
  successful import, bad hash, cancellation, atomic replacement, cleanup and URLs;
  not a substitute for Files-provider/phone-network acceptance.

## Confirmed initialization defect
The pinned MLX Qwen snapshot `0d6bb6fe33f92d47a507e23b9148940e8366ab5b` has vocab.json,
merges.txt and tokenizer_config.json, but no tokenizer.json. swift-transformers 1.0.0
AutoTokenizer.from(modelFolder:) needs tokenizer.json. The previous package verified
only weight hashes, allowing this missing resource through. Loading weights before
discovering the missing tokenizer also wasted memory/time. This establishes the
resource error, not every cause of the reported phone stalls.

## Fix and isolation
- Build-time conversion with transformers 4.57.3 / tokenizers 0.22.2, using the exact
  snapshot vocabulary and added TTS tokens. Slow/fast Python token IDs must agree.
- CI runs the actual Swift tokenizer against six Python fixtures, including Chinese,
  mixed text, emoji and TTS special tokens, before building the app.
- Qwen loader checks required resources and constructs its tokenizer before weights.
- Separate opt-in workflow enables QWEN_LAB; ordinary mobile-ci and Android stay lite.
- Only tokenizer/config/reference resources are bundled. User-triggered downloads
  store hash-verified model weights under Application Support, excluded from backup.
- A single background actor owns the model; shared main-thread UI state prevents
  overlapping jobs on reopening the sheet. No startup model load or book integration.
- Model reuse between reference voices; close/cancel/background/memory warning request
  cooperative cancellation and release. GPU operations already running cannot be
  forcibly interrupted safely; UI says it is waiting for safe exit.
- Foreground short samples only, <=40 characters, 192-frame guard and cooperative
  120-second deadline. Frame limit rejects potentially truncated samples. Thermal
  and physical-memory checks are admission guards, not proof against OS termination.
- Download bytes, generation frames, elapsed time and measured generation/audio ratio
  are visible. No artificial progress percentage. No book content uploaded.

## Acceptance still requiring iPhone
Install signed experimental IPA; More > Offline Voice Lab; download/verify on Wi-Fi.
Switch airplane mode on; test voices 4 and 1 repeatedly, cancel during generation,
close/reopen while cancelling, and return to library to scroll/open a book. Record
load/generation/audio times, listen for complete text, and inspect memory/thermal
behavior. Simulator/tokenizer/IPA checks are NOT successful device inference.
Do not integrate into continuous reading until this passes.

## Published verification — 2026-09-17
- Source: `4a344200ef3dd4d1dc84b2d9317e4da4c2df61b4`.
- Actions run `35219835451` completed successfully: Python conversion, actual Swift
  tokenizer parity, existing TXT/speech-queue tests, unsigned iOS build, packaging,
  archive validation and prerelease publication.
- Release: https://github.com/yb19910212/guiye-reader/releases/tag/ios-lab-1
- Final asset `GuiyeReader-ios-offline-lab-unsigned.ipa` was downloaded from that
  non-draft release and rechecked locally with `verify_qwen_lab.py`.
- Size: 19,152,488 bytes. SHA256:
  `0ec5f8a2a5114428688ae19747ebefbc0b3dcb9bad71ee18d6ef596d8bb8ee4f`, matching GitHub's digest.
- Complete tokenizer/configs/reference WAVs and Metal library present; no bundled
  safetensors/ONNX weights. Remote pinned weight hashes also match upstream metadata:
  main 1,024,490,700 bytes; speech tokenizer 682,293,092 bytes (about 1.7 GB total).
- Android and ordinary Mobile CI were intentionally not changed/rebuilt.
- No physical iPhone was connected. This proves the missing-tokenizer repair and
  package integrity, NOT successful on-device model inference or smooth playback.

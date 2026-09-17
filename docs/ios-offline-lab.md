# iOS offline voice lab

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

# Selected original synthetic voices

- gentle.wav: preview 1, Qwen3-TTS-12Hz-1.7B-VoiceDesign, seed 20260917.
- coaxing.wav: preview 4, same source model and seed, sweeter instruction.
- Mono PCM16, 24000 Hz. These are references for Base-model conditioning,
  not a speech engine and not recordings of a real person.
- Transcript: 你回来啦，今天辛苦了。要不要坐下来，让我陪你读一会儿书？别着急，今晚的故事，我们慢慢听。

On-device model: mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit (Apache-2.0),
revision 0d6bb6fe33f92d47a507e23b9148940e8366ab5b.
The original Kokoro model remains bundled. Quantized voice cloning may differ
from the reference; native runtime quality/performance needs device validation.

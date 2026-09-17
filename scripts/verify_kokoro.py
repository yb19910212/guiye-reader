#!/usr/bin/env python3
"""Generate a short sentence to prove the bundled Kokoro model is usable."""

from pathlib import Path
import sys

import sherpa_onnx


def main() -> None:
    base = Path(sys.argv[1]).resolve()
    kokoro = sherpa_onnx.OfflineTtsKokoroModelConfig(
        model=str(base / "model.int8.onnx"),
        voices=str(base / "voices.bin"),
        tokens=str(base / "tokens.txt"),
        data_dir=str(base / "espeak-ng-data"),
        lexicon=f"{base / 'lexicon-us-en.txt'},{base / 'lexicon-zh.txt'}",
    )
    config = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(kokoro=kokoro, num_threads=4),
        rule_fsts=",".join(
            str(base / name)
            for name in ("date-zh.fst", "phone-zh.fst", "number-zh.fst")
        ),
        max_num_sentences=1,
    )
    tts = sherpa_onnx.OfflineTts(config)
    audio = tts.generate(text="归页离线语音测试。", sid=3, speed=1.0)
    peak = max((abs(float(sample)) for sample in audio.samples), default=0.0)
    assert audio.sample_rate == 24_000, audio.sample_rate
    assert len(audio.samples) > 2_400, len(audio.samples)
    assert peak > 0.01, peak
    print(
        f"Kokoro runtime OK: sid=3, samples={len(audio.samples)}, "
        f"rate={audio.sample_rate}, peak={peak:.3f}"
    )


if __name__ == "__main__":
    main()

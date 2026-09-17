"""Fetch pinned, Apache-2.0 mobile model resources at build time, never at runtime."""
import hashlib
from pathlib import Path
import sys
import urllib.request

REVISION = "0d6bb6fe33f92d47a507e23b9148940e8366ab5b"
BASE = f"https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit/resolve/{REVISION}/"
FILES = ["README.md", "config.json", "generation_config.json", "merges.txt",
         "model.safetensors", "model.safetensors.index.json", "preprocessor_config.json",
         "speech_tokenizer/config.json", "speech_tokenizer/configuration.json",
         "speech_tokenizer/model.safetensors", "speech_tokenizer/preprocessor_config.json",
         "tokenizer_config.json", "vocab.json"]
HASHES = {
    "model.safetensors": "07dcb37b323614af64624af687876edd5c9a8b442da2a7b549d62f9ba2770ec1",
    "speech_tokenizer/model.safetensors": "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
}

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()

def main():
    target = Path(sys.argv[1]).resolve()
    for name in FILES:
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if name in HASHES and path.exists() and digest(path) == HASHES[name]:
            continue
        partial = path.with_suffix(path.suffix + ".partial")
        print("Fetching", name, flush=True)
        urllib.request.urlretrieve(BASE + name, partial)
        if name in HASHES and digest(partial) != HASHES[name]:
            raise RuntimeError("Model checksum mismatch: " + name)
        partial.replace(path)
    print("Pinned Qwen model downloaded and weight checksums verified", flush=True)

if __name__ == "__main__":
    main()

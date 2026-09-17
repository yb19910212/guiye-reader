"""Fetch pinned, Apache-2.0 mobile model resources at build time, never at runtime."""
import hashlib
import argparse
import json
from pathlib import Path
import sys
import urllib.request
import socket

socket.setdefaulttimeout(120)

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
    parser = argparse.ArgumentParser()
    parser.add_argument('target', type=Path)
    parser.add_argument('--support-only', action='store_true', help='Bundle metadata; download weights only on user request')
    args = parser.parse_args()
    target = args.target.resolve()
    for name in FILES:
        if args.support_only and name in HASHES:
            continue
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
    # This pinned upstream revision contains vocab/merges but NO tokenizer.json.
    # swift-transformers requires the unified fast-tokenizer representation.
    # Convert the exact local vocabulary, including all TTS special-token IDs.
    from transformers import Qwen2Tokenizer, Qwen2TokenizerFast
    slow = Qwen2Tokenizer.from_pretrained(target, local_files_only=True)
    fast = Qwen2TokenizerFast.from_pretrained(target, local_files_only=True)
    cases = ['你好，今天我们一起读书。', '温柔一点，别着急。', 'Hello, 123! café',
             '<|im_start|>assistant\n<tts_text_bos>你好<tts_text_eod><|im_end|>',
             '第一章\n夜色安静下来。🙂', '你回来啦，今天辛苦了。']
    fixtures = []
    for text in cases:
        ids = fast.encode(text, add_special_tokens=False)
        assert ids == slow.encode(text, add_special_tokens=False), text
        fixtures.append(dict(text=text, ids=ids))
    for token, expected in {'<|im_start|>':151644, '<|im_end|>':151645,
                            '<tts_pad>':151671, '<tts_text_bos>':151672,
                            '<tts_text_eod>':151673}.items():
        assert fast.convert_tokens_to_ids(token) == expected, token
    fast.backend_tokenizer.save(str(target / 'tokenizer.json'))
    (target / 'tokenizer-fixtures.json').write_text(json.dumps(fixtures, ensure_ascii=False), encoding='utf-8')
    urllib.request.urlretrieve('https://www.apache.org/licenses/LICENSE-2.0.txt', target / 'MODEL-LICENSE.txt')
    (target / 'MODEL-NOTICE.txt').write_text(
        'Qwen3-TTS-12Hz-0.6B-Base-4bit\nPublisher: mlx-community; original model: Qwen/Qwen3-TTS-12Hz-0.6B-Base\n'
        f'Revision: {REVISION}\nLicense: Apache-2.0\n'
        'https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit\n'
        'tokenizer.json is converted from the pinned vocabulary for Swift compatibility.\n', encoding='utf-8')
    entries = []
    for name in FILES + ['tokenizer.json', 'tokenizer-fixtures.json', 'MODEL-LICENSE.txt', 'MODEL-NOTICE.txt']:
        entries.append(dict(path=name, sha256=HASHES.get(name) or digest(target / name),
                            url=BASE + name if name in HASHES and args.support_only else None))
    (target / 'manifest.json').write_text(json.dumps(dict(revision=REVISION, files=entries), indent=2), encoding='utf-8')
    print('Swift tokenizer generated; slow/fast IDs and TTS special tokens verified', flush=True)

if __name__ == "__main__":
    main()

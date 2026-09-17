"""Inspect downloaded v0.14.0 release packages without installing them.

This verifies packaging, not phone runtime stability or voice quality.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import zipfile

from prepare_qwen_model import HASHES, digest


def archive_hash(archive, name):
    result = hashlib.sha256()
    with archive.open(name) as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify(directory):
    ipa = directory / "GuiyeReader-unsigned.ipa"
    apk = directory / "GuiyeReader-android.apk"
    base = "Payload/GuiyeReader.app/"
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read(base + "Info.plist"))
        assert info["CFBundleShortVersionString"] == "0.14.0", info
        assert str(info["CFBundleVersion"]) == "19", info
        assert info["MinimumOSVersion"] == "18.0", info
        assert archive.getinfo(base + "KokoroModel/model.int8.onnx").file_size > 0
        assert any(name.endswith(".metallib") for name in archive.namelist())
        for name, expected in HASHES.items():
            assert archive_hash(archive, base + "QwenModel/" + name) == expected, name
        references = {
            "gentle.wav": "3f54e8dbd84bbb60b94fd3c195903a2685973f3248fe2b9d0a83088e63cc0b1d",
            "coaxing.wav": "0d1a0e56b7ee396f0288385de3b65130c125cb07f810cd91313b6800b65846f7",
        }
        for name, expected in references.items():
            assert archive_hash(archive, base + "VoiceReferences/" + name) == expected, name
    with zipfile.ZipFile(apk) as archive:
        assert archive.getinfo("assets/kokoro-int8-multi-lang-v1_1/model.int8.onnx").file_size > 0
        assert any(name.startswith("lib/arm64-v8a/") and name.endswith(".so") for name in archive.namelist())
        assert archive.testzip() is None, "APK checksum failure"
    for path in (ipa, apk):
        print(json.dumps({"file": path.name, "bytes": path.stat().st_size,
                          "sha256": digest(path)}, ensure_ascii=False))
    print("Release resource checks passed. Device performance remains unverified.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))

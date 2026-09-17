"""Fail CI if a release accidentally bundles retired neural engines or weights."""
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as package:
    names = package.namelist()
    forbidden = ("kokoro", "sherpa", "qwenmodel", "voicereferences", ".safetensors", ".onnx", "mlx.framework")
    found = [name for name in names if any(part in name.lower() for part in forbidden)]
    assert not found, "Retired model resources found: " + repr(found[:10])
    assert len(names) > 1, "Empty package"
print("Lightweight package check passed")

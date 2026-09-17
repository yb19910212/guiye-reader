"""Inspect the actual IPA: tokenizer present and valid, weights NOT bundled."""
import hashlib
import json
import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as package:
    base = 'Payload/GuiyeReader.app/'
    info = plistlib.loads(package.read(base + 'Info.plist'))
    assert info['CFBundleShortVersionString'] == '0.17.1'
    assert str(info['CFBundleVersion']) == '23'
    names = package.namelist()
    assert not any(name.endswith(('.safetensors', '.onnx')) for name in names)
    assert any(name.endswith('.metallib') for name in names), 'Missing MLX Metal library'
    manifest = json.loads(package.read(base + 'QwenSupport/manifest.json'))
    for entry in manifest['files']:
        if entry['url'] is None:
            data = package.read(base + 'QwenSupport/' + entry['path'])
            assert hashlib.sha256(data).hexdigest() == entry['sha256'], entry['path']
    tokenizer = json.loads(package.read(base + 'QwenSupport/tokenizer.json'))
    tokens = {x['content']: x['id'] for x in tokenizer['added_tokens']}
    assert tokens['<tts_text_bos>'] == 151672
    assert tokens['<tts_text_eod>'] == 151673
    for name in ['gentle.wav', 'coaxing.wav']:
        assert len(package.read(base + 'VoiceReferences/' + name)) > 44
    assert package.testzip() is None
print('Experimental IPA verified: complete tokenizer, Metal runtime, references; no bundled model weights')

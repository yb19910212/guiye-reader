"""Inspect the actual complete IPA, including streamed model-weight hashes."""
import hashlib
import json
import plistlib
import sys
import zipfile
from prepare_qwen_model import HASHES

with zipfile.ZipFile(sys.argv[1]) as package:
    base = 'Payload/GuiyeReader.app/'
    info = plistlib.loads(package.read(base + 'Info.plist'))
    assert info['CFBundleShortVersionString'] == '0.18.1'
    assert str(info['CFBundleVersion']) == '26'
    names = package.namelist()
    for name in HASHES:
        assert package.getinfo(base + 'QwenSupport/' + name).file_size > 600_000_000, name
    assert any(name.endswith('.metallib') for name in names), 'Missing MLX Metal library'
    manifest = json.loads(package.read(base + 'QwenSupport/manifest.json'))
    for entry in manifest['files']:
        assert entry['url'] is None, 'Complete package must not need runtime downloads'
        digest = hashlib.sha256()
        with package.open(base + 'QwenSupport/' + entry['path']) as stream:
            for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
                digest.update(block)
        assert digest.hexdigest() == entry['sha256'], entry['path']
        if entry['path'] in HASHES:
            assert digest.hexdigest() == HASHES[entry['path']], entry['path']
    tokenizer = json.loads(package.read(base + 'QwenSupport/tokenizer.json'))
    tokens = {x['content']: x['id'] for x in tokenizer['added_tokens']}
    assert tokens['<tts_text_bos>'] == 151672
    assert tokens['<tts_text_eod>'] == 151673
    for name in ['gentle.wav', 'coaxing.wav']:
        assert len(package.read(base + 'VoiceReferences/' + name)) > 44
    assert package.testzip() is None
print('Complete IPA verified: pinned weight hashes, tokenizer, Metal runtime, references; no model download required')

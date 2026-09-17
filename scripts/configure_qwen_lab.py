"""Enable the opt-in iOS lab in a disposable CI checkout, not the lite project."""
from pathlib import Path

path = Path('ios/GuiyeReader.xcodeproj/project.pbxproj')
text = path.read_text(encoding='utf-8')
assert 'QWEN_LAB' not in text, 'Already configured'
objects = '''
        EE0000000000000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OfflineVoiceLab.swift; sourceTree = "<group>"; };
        EE0000000000000000000002 = {isa = PBXBuildFile; fileRef = EE0000000000000000000001; };
        EE0000000000000000000003 = {isa = PBXFileReference; lastKnownFileType = folder; path = QwenSupport; sourceTree = "<group>"; };
        EE0000000000000000000004 = {isa = PBXBuildFile; fileRef = EE0000000000000000000003; };
        EE0000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = folder; path = VoiceReferences; sourceTree = "<group>"; };
        EE0000000000000000000006 = {isa = PBXBuildFile; fileRef = EE0000000000000000000005; };
        EE0000000000000000000007 = {isa = XCLocalSwiftPackageReference; relativePath = ../vendor/Qwen3TTS; };
        EE0000000000000000000008 = {isa = XCSwiftPackageProductDependency; package = EE0000000000000000000007; productName = Qwen3TTS; };
        EE0000000000000000000009 = {isa = PBXBuildFile; productRef = EE0000000000000000000008; };
'''
text = text.replace('objects = {', 'objects = {' + objects, 1)
text = text.replace('path = GuiyeReader; sourceTree = "<group>"; children = (',
                    'path = GuiyeReader; sourceTree = "<group>"; children = (EE0000000000000000000001,EE0000000000000000000003,EE0000000000000000000005,')
for phase, entry in [('PBXSourcesBuildPhase', 'EE0000000000000000000002'),
                     ('PBXResourcesBuildPhase', 'EE0000000000000000000004,EE0000000000000000000006'),
                     ('PBXFrameworksBuildPhase', 'EE0000000000000000000009')]:
    text = text.replace(f'isa = {phase}; buildActionMask = 2147483647; files = (',
                        f'isa = {phase}; buildActionMask = 2147483647; files = ({entry},')
text = text.replace('packageReferences = (', 'packageReferences = (EE0000000000000000000007,')
text = text.replace('packageProductDependencies = (', 'packageProductDependencies = (EE0000000000000000000008,')
text = text.replace('SWIFT_VERSION = 5.0;', 'SWIFT_VERSION = 5.0; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) QWEN_LAB";')
text = text.replace('CURRENT_PROJECT_VERSION = 21;', 'CURRENT_PROJECT_VERSION = 22;')
text = text.replace('MARKETING_VERSION = 0.16.0;', 'MARKETING_VERSION = 0.17.0;')
path.write_text(text, encoding='utf-8')


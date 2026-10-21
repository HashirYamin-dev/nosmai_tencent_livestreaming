#!/usr/bin/env python3
"""Configure a newly generated tencent_flutter_live Android/iOS project.

Leaves Flutter's own Gradle/plugin versions, app delegates, signing, and generated
registrants intact. Supports Kotlin and Groovy app Gradle files. Idempotent.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ANDROID_NS = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID_NS)
A = '{' + ANDROID_NS + '}'
MARKER = 'TENCENT_LIVE_CONFIGURATION'


def patch_gradle(text: str, kotlin: bool) -> str:
    if MARKER in text:
        return text
    if kotlin:
        block = '''    // TENCENT_LIVE_CONFIGURATION
    packaging {
        jniLibs {
            pickFirsts += setOf("lib/**/libliteavsdk.so")
        }
    }
'''
        release = '''
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
'''
        text = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion',
                      'compileSdk = maxOf(flutter.compileSdkVersion, 35)', text)
        text = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion',
                      'minSdk = maxOf(flutter.minSdkVersion, 23)', text)
    else:
        block = '''    // TENCENT_LIVE_CONFIGURATION
    packagingOptions {
        jniLibs {
            pickFirsts += ["lib/**/libliteavsdk.so"]
        }
    }
'''
        release = '''
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
'''
        text = re.sub(r'compileSdk(?:Version)?\s*(?:=\s*)?flutter\.compileSdkVersion',
                      'compileSdkVersion Math.max(flutter.compileSdkVersion, 35)', text)
        text = re.sub(r'minSdk(?:Version)?\s*(?:=\s*)?flutter\.minSdkVersion',
                      'minSdkVersion Math.max(flutter.minSdkVersion, 23)', text)
    text, count = re.subn(r'(?m)^android\s*\{\s*\n', 'android {\n' + block, text, count=1)
    if count != 1:
        raise ValueError('Generated app Gradle android block was not found. No files changed.')
    # Flutter templates use release { ... }; support named Kotlin containers too.
    pattern = r'(\brelease\s*\{|getByName\("release"\)\s*\{)'
    text, count = re.subn(pattern, lambda m: m.group(0) + release, text, count=1)
    if count != 1:
        raise ValueError('Generated app Gradle release block was not found. No files changed.')
    return text


def patch_manifest(text: str) -> str:
    root = ET.fromstring(text)
    permissions = [
        'INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE',
        'RECORD_AUDIO', 'MODIFY_AUDIO_SETTINGS', 'CAMERA', 'BLUETOOTH',
    ]
    for permission in permissions:
        name = 'android.permission.' + permission
        item = next((x for x in root.findall('uses-permission') if x.get(A+'name') == name), None)
        if item is None:
            item = ET.Element('uses-permission', {A+'name': name})
            root.insert(0, item)
        if permission == 'BLUETOOTH':
            item.set(A+'maxSdkVersion', '30')
    for name in ('android.hardware.camera', 'android.hardware.camera.autofocus',
                 'android.hardware.camera.front', 'android.hardware.microphone'):
        item = next((x for x in root.findall('uses-feature') if x.get(A+'name') == name), None)
        if item is None:
            item = ET.Element('uses-feature', {A+'name': name})
            root.insert(0, item)
        item.set(A+'required', 'false')
    app = root.find('application')
    if app is None:
        raise ValueError('AndroidManifest.xml has no application element.')
    app.set(A+'label', 'Tencent Live')
    ET.indent(root, space='    ')
    return ET.tostring(root, encoding='unicode') + '\n'


def patch_xcode(text: str) -> str:
    def minimum(match: re.Match) -> str:
        current = float(match.group(1))
        return 'IPHONEOS_DEPLOYMENT_TARGET = ' + (match.group(1) if current >= 15 else '15.0') + ';'
    text = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);', minimum, text)
    # Change only the generated project's bundle IDs; preserve the test suffix.
    text = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);',
                  lambda m: 'PRODUCT_BUNDLE_IDENTIFIER = com.vativeapps.tencentlive' +
                  ('.RunnerTests' if 'RunnerTests' in m.group(1) else '') + ';', text)
    pattern = re.compile(
        r'(?ms)^([ \t]*[A-F0-9]{24} /\* (Debug|Release|Profile) \*/ = \{\n'
        r'[ \t]*isa = XCBuildConfiguration;\n.*?\n[ \t]*name = \2;\n[ \t]*\};)')
    count = 0
    def configure(match: re.Match) -> str:
        nonlocal count
        block = match.group(1)
        if match.group(2) == 'Debug':
            return block
        count += 1
        for key, value in (('DEPLOYMENT_POSTPROCESSING', 'YES'), ('STRIP_STYLE', '"non-global"')):
            if re.search(r'\b' + key + r'\s*=', block):
                block = re.sub(r'\b' + key + r'\s*=\s*[^;]+;', key+' = '+value+';', block)
            else:
                block = block.replace('buildSettings = {', 'buildSettings = {\n\t\t\t\t'+key+' = '+value+';', 1)
        return block
    text = pattern.sub(configure, text)
    if count == 0:
        raise ValueError('Xcode Release/Profile configurations were not recognized. No files changed.')
    return text


def make_podfile(has_tests: bool) -> str:
    tests = "  target 'RunnerTests' do\n    inherit! :search_paths\n  end\n" if has_tests else ''
    return '''# TENCENT_LIVE_CONFIGURATION - generated for this standalone app only.
platform :ios, '15.0'
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  config = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  raise "Run flutter pub get before pod install" unless File.exist?(config)
  File.foreach(config) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT missing from Generated.xcconfig. Run flutter pub get."
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)
flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
''' + tests + '''end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' if current < 15.0
      definitions = Array(config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] || ['$(inherited)'])
      definitions += ['PERMISSION_CAMERA=1', 'PERMISSION_MICROPHONE=1']
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = definitions.uniq
      unless config.name == 'Debug'
        # Preserve the C symbols accessed by Tencent's Dart FFI bindings.
        config.build_settings['DEPLOYMENT_POSTPROCESSING'] = 'YES'
        config.build_settings['STRIP_STYLE'] = 'non-global'
      end
    end
  end
end
'''


def patch_project(root: Path) -> list[str]:
    root = root.resolve()
    if not re.search(r'(?m)^name:\s*tencent_flutter_live\s*$', (root/'pubspec.yaml').read_text()):
        raise ValueError('This tool only configures the standalone tencent_flutter_live project.')
    writes: dict[Path, bytes] = {}
    gradle = root/'android/app/build.gradle.kts'
    kotlin = gradle.exists()
    if not kotlin:
        gradle = root/'android/app/build.gradle'
    writes[gradle] = patch_gradle(gradle.read_text(), kotlin).encode()
    manifest = root/'android/app/src/main/AndroidManifest.xml'
    writes[manifest] = patch_manifest(manifest.read_text()).encode()
    writes[root/'android/app/proguard-rules.pro'] = (
        '# Tencent FFI/JNI and native callback entry points.\n'
        '-keep class com.tencent.** { *; }\n'
        '-keepclasseswithmembernames class * { native <methods>; }\n'
    ).encode()
    info_path = root/'ios/Runner/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update({
        'CFBundleDisplayName': 'Tencent Live',
        'NSCameraUsageDescription': 'Start Live uses the camera to broadcast your video.',
        'NSMicrophoneUsageDescription': 'Start Live uses the microphone to broadcast your voice.',
        'io.flutter.embedded_views_preview': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
        'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait'],
    })
    writes[info_path] = plistlib.dumps(info, sort_keys=False)
    pbx_path = root/'ios/Runner.xcodeproj/project.pbxproj'
    pbx_text = pbx_path.read_text()
    writes[pbx_path] = patch_xcode(pbx_text).encode()
    writes[root/'ios/Podfile'] = make_podfile('RunnerTests' in pbx_text).encode()
    framework_info = root/'ios/Flutter/AppFrameworkInfo.plist'
    if framework_info.exists():
        framework = plistlib.loads(framework_info.read_bytes())
        framework['MinimumOSVersion'] = '15.0'
        writes[framework_info] = plistlib.dumps(framework, sort_keys=False)
    # New SwiftPM-oriented templates may omit these CocoaPods xcconfig includes.
    for name in ('Debug', 'Release'):
        path = root/f'ios/Flutter/{name}.xcconfig'
        text = path.read_text() if path.exists() else '#include "Generated.xcconfig"\n'
        include = f'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.{name.lower()}.xcconfig"'
        if include not in text:
            text = include + '\n' + text
        writes[path] = text.encode()
    # Validate all transformations before modifying files.
    for path, data in writes.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return [str(path.relative_to(root)) for path in writes]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', nargs='?', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        for path in patch_project(args.project):
            print('Configured ' + path)
        return 0
    except (ValueError, OSError, ET.ParseError, plistlib.InvalidFileException) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

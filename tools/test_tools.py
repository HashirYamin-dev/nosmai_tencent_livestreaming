"""Local Python/bootstrap tests. No real Tencent credentials or SDK are used."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
import zlib

from configure import generate_usersig, make_config, read_metadata, validate_identity, write_config
from patch_native import patch_gradle, patch_manifest, patch_project, patch_xcode, make_podfile

PROJECT = Path(__file__).resolve().parents[1]
KOTLIN = '''plugins { id("com.android.application") }
android {
    namespace = "com.vativeapps.tencent_flutter_live"
    compileSdk = flutter.compileSdkVersion
    defaultConfig {
        applicationId = "com.vativeapps.tencent_flutter_live"
        minSdk = flutter.minSdkVersion
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'''
GROOVY = '''android {
    compileSdkVersion flutter.compileSdkVersion
    defaultConfig {
        minSdkVersion flutter.minSdkVersion
    }
    buildTypes {
        release {
            signingConfig signingConfigs.debug
        }
    }
}
'''
MANIFEST = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
<application android:label="original" android:name="${applicationName}">
<activity android:name=".MainActivity" android:exported="true" />
</application></manifest>'''


def pbx_fixture() -> str:
    blocks = []
    for i, name in enumerate(('Debug', 'Release', 'Profile')):
        blocks.append(f'''\t\t{i+1:024X} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.demo;
\t\t\t}};
\t\t\tname = {name};
\t\t}};''')
    return '// !$*UTF8*$!\n/* RunnerTests */\n' + '\n'.join(blocks) + '\n'


def native_fixture(root: Path, *, kotlin: bool = True) -> None:
    files = {
        'android/app/build.gradle.kts' if kotlin else 'android/app/build.gradle': KOTLIN if kotlin else GROOVY,
        'android/app/src/main/AndroidManifest.xml': MANIFEST,
        'ios/Runner.xcodeproj/project.pbxproj': pbx_fixture(),
        'ios/Flutter/Debug.xcconfig': '#include "Generated.xcconfig"\n',
        'ios/Flutter/Release.xcconfig': '#include "Generated.xcconfig"\n',
    }
    for name, text in files.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for name, data in {
        'ios/Runner/Info.plist': {'CFBundleName': 'generated'},
        'ios/Flutter/AppFrameworkInfo.plist': {'MinimumOSVersion': '12.0'},
    }.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(data))
    if not (root/'pubspec.yaml').exists():
        (root/'pubspec.yaml').write_text('name: tencent_flutter_live\n')


class SignatureTests(unittest.TestCase):
    def test_hmac_matches_independent_canonical_calculation(self):
        sig = generate_usersig(1400000000, 'not-a-real-secret', 'host_001', 86400, 1700000000)
        decoded = read_metadata(sig)
        canonical = b'TLS.identifier:host_001\nTLS.sdkappid:1400000000\nTLS.time:1700000000\nTLS.expire:86400\n'
        expected = base64.b64encode(hmac.new(b'not-a-real-secret', canonical, hashlib.sha256).digest()).decode()
        self.assertEqual(decoded['TLS.sig'], expected)
        self.assertEqual(decoded['TLS.expire'], 86400)
        self.assertFalse(any(c in sig for c in '+/='))
        self.assertNotIn('not-a-real-secret', json.dumps(decoded))

    def test_different_users_and_keys_produce_different_signatures(self):
        a = generate_usersig(1, 'key-A', 'a', now=1700000000)
        b = generate_usersig(1, 'key-A', 'b', now=1700000000)
        c = generate_usersig(1, 'key-B', 'a', now=1700000000)
        self.assertEqual(len({a, b, c}), 3)

    def test_identity_validation(self):
        for app_id, user in [(0, 'a'), (True, 'a'), (2**32, 'a'), (1, 'a b'), (1, ''), (1, 'x'*33)]:
            with self.subTest(app_id=app_id, user=user), self.assertRaises(ValueError):
                validate_identity(app_id, user)

    def test_secret_and_lifetime_validation(self):
        for key, expiry in [('', 86400), ('key', 0), ('key', 8*86400)]:
            with self.subTest(key=key, expiry=expiry), self.assertRaises(ValueError):
                generate_usersig(1, key, 'a', expiry)

    def test_config_identity_expiry_and_secret_exclusion(self):
        sig = generate_usersig(123, 'demo-secret', 'viewer_001')
        config = make_config(123, 'viewer_001', sig)
        self.assertEqual(set(config), {'SDK_APP_ID', 'USER_ID', 'USER_SIG', 'TOKEN_EXPIRES_AT'})
        self.assertNotIn('demo-secret', json.dumps(config))
        self.assertGreater(config['TOKEN_EXPIRES_AT'], int(time.time()))
        for app_id, user in [(124, 'viewer_001'), (123, 'host_001')]:
            with self.assertRaises(ValueError):
                make_config(app_id, user, sig)

    def test_expired_sig_rejected(self):
        sig = generate_usersig(123, 'key', 'host_001', 1, now=1)
        with self.assertRaises(ValueError):
            make_config(123, 'host_001', sig)

    def test_bad_and_oversized_input_rejected(self):
        bomb = base64.b64encode(zlib.compress(b'x'*100000)).decode().translate(str.maketrans('+/=', '*-_'))
        for sig in ['', 'not valid!!!', 'x'*9000, bomb]:
            with self.subTest(length=len(sig)), self.assertRaises(ValueError):
                read_metadata(sig)

    def test_private_atomic_file_and_symlink_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'config'/'host.json'
            write_config(path, {'safe': 'fixture'})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(path.read_text()), {'safe': 'fixture'})
            link = path.parent/'link.json'
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                write_config(link, {'unsafe': True})


class NativePatchingTests(unittest.TestCase):
    def test_kotlin_and_groovy_idempotence(self):
        for fixture, kotlin in [(KOTLIN, True), (GROOVY, False)]:
            with self.subTest(kotlin=kotlin):
                result = patch_gradle(fixture, kotlin)
                self.assertIn('lib/**/libliteavsdk.so', result)
                self.assertIn('proguard-rules.pro', result)
                self.assertIn('35)', result)
                self.assertIn('23)', result)
                self.assertEqual(result, patch_gradle(result, kotlin))

    def test_unknown_gradle_rejected(self):
        with self.assertRaises(ValueError):
            patch_gradle('not a generated Gradle project', True)

    def test_manifest_permissions_and_no_unnecessary_storage(self):
        result = patch_manifest(MANIFEST)
        self.assertIn('android.permission.CAMERA', result)
        self.assertIn('android.permission.RECORD_AUDIO', result)
        self.assertNotIn('WRITE_EXTERNAL_STORAGE', result)
        self.assertIn('${applicationName}', result)
        self.assertEqual(result, patch_manifest(result))

    def test_ios_release_ffi_fix_and_minimum(self):
        result = patch_xcode(pbx_fixture())
        self.assertEqual(result.count('DEPLOYMENT_POSTPROCESSING = YES;'), 2)
        self.assertEqual(result.count('STRIP_STYLE = "non-global";'), 2)
        self.assertEqual(result.count('IPHONEOS_DEPLOYMENT_TARGET = 15.0;'), 3)
        self.assertEqual(result, patch_xcode(result))

    def test_full_generated_fixture_and_idempotence(self):
        for kotlin in (True, False):
            with self.subTest(kotlin=kotlin), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                native_fixture(root, kotlin=kotlin)
                written = patch_project(root)
                before = {name: (root/name).read_bytes() for name in written}
                patch_project(root)
                self.assertEqual(before, {name: (root/name).read_bytes() for name in written})
                info = plistlib.loads((root/'ios/Runner/Info.plist').read_bytes())
                self.assertIn('NSMicrophoneUsageDescription', info)
                self.assertIn('PERMISSION_CAMERA=1', (root/'ios/Podfile').read_text())
                self.assertIn('Pods-Runner.debug.xcconfig', (root/'ios/Flutter/Debug.xcconfig').read_text())

    def test_validation_happens_before_project_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native_fixture(root)
            (root/'ios/Runner.xcodeproj/project.pbxproj').write_text('unrecognized')
            original = (root/'android/app/build.gradle.kts').read_text()
            with self.assertRaises(ValueError):
                patch_project(root)
            self.assertEqual((root/'android/app/build.gradle.kts').read_text(), original)
            self.assertFalse((root/'ios/Podfile').exists())

    @unittest.skipUnless(shutil.which('ruby'), 'Ruby is not installed')
    def test_generated_podfile_ruby_syntax(self):
        for has_tests in (True, False):
            with self.subTest(has_tests=has_tests):
                proc = subprocess.run(['ruby', '-c'], input=make_podfile(has_tests), text=True, capture_output=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)


class BootstrapTests(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = list(PROJECT.rglob('*.sh'))
        outer = PROJECT.parent/'install.sh'
        if outer.exists():
            scripts.append(outer)
        for script in scripts:
            with self.subTest(script=script.name):
                proc = subprocess.run(['bash', '-n', str(script)], capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)

    @unittest.skipUnless((PROJECT.parent/'install.sh').exists(), 'Kit installer not in an installed project')
    def test_installer_with_mock_flutter_and_path_spaces(self):
        # This is script orchestration only. It is NOT a Flutter compile/test run.
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            fake = work/'mock flutter'
            fake.write_text('#!/usr/bin/env python3\n' +
                'import sys,json\nfrom pathlib import Path\n' +
                f'sys.path.insert(0,{str(PROJECT / "tools")!r})\n' +
                'from test_tools import native_fixture\n' +
                'if "--version" in sys.argv:\n print(json.dumps({"frameworkVersion":"3.47.4"}))\n' +
                'elif "create" in sys.argv:\n native_fixture(Path.cwd())\n' +
                'else:\n print("MOCK ONLY: " + " ".join(sys.argv[1:]))\n')
            fake.chmod(0o755)
            target = work/'new project with spaces'
            env = dict(os.environ, FLUTTER_BIN=str(fake))
            proc = subprocess.run(['bash', str(PROJECT.parent/'install.sh'), str(target)],
                                  env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stdout+'\n'+proc.stderr)
            self.assertIn('tencent_rtc_sdk: 13.5.2', (target/'pubspec.yaml').read_text())
            self.assertIn('enable-swift-package-manager: false', (target/'pubspec.yaml').read_text())
            self.assertTrue((target/'lib/live_session.dart').exists())
            self.assertTrue((target/'README.md').exists())
            repeated = subprocess.run(['bash', str(PROJECT.parent/'install.sh'), str(target)],
                                      env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn('Nothing was overwritten', repeated.stdout+repeated.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

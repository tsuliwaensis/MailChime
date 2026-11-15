#!/usr/bin/env python3
"""Run the built app's credential-free worker diagnostic; create no login item."""
from pathlib import Path
import plistlib
import subprocess
import sys
app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.rhpt.mailchime', 'App identifier mismatch'
agent = plistlib.loads((app / 'Contents/Library/LaunchAgents/com.rhpt.mailchime.agent.plist').read_bytes())
assert agent['Label'] == 'com.rhpt.mailchime.agent', 'Agent identifier mismatch'
assert sorted(p.name for p in (app / 'Contents/Library/LaunchAgents').glob('*.plist')) == ['com.rhpt.mailchime.agent.plist'], 'Stale agent plist in bundle'
executable = app / agent['BundleProgram']
assert executable.is_file(), 'Embedded agent executable missing'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
result = subprocess.run([str(executable), '--diagnose'], capture_output=True, text=True, timeout=15)
assert result.returncode == 0, 'Worker diagnostic failed'
assert 'Credential-free worker diagnostic passed.' in result.stdout
print('App signature, embedded launch agent, and credential-free worker runtime passed.')

assert info['CFBundleName'] == 'MailChime' and info['CFBundleDisplayName'] == 'MailChime'
assert info.get('CFBundleIconFile') == 'NewAppIcon' and info.get('CFBundleIconName') == 'NewAppIcon', 'Compiled app icon mismatch'
assert (app / 'Contents/Resources/NewAppIcon.icns').is_file() and (app / 'Contents/Resources/Assets.car').is_file(), 'Compiled NewAppIcon resources missing'
assert not (app / 'Contents/Resources/AppIcon.icns').exists(), 'Stale AppIcon.icns in bundle'
assert info['NSHumanReadableCopyright'] == '© 2026 RHPT.\nLicensed under the MIT License.\nBased on MailBell by Marton Paulo and Samzong.'
assert info['CFBundleShortVersionString'] and '$(' not in info['CFBundleShortVersionString']
assert info['CFBundleVersion'] and '$(' not in info['CFBundleVersion']
result = subprocess.run([str(executable), '--diagnose-interface'], capture_output=True, text=True, timeout=20)
assert result.returncode == 0, result.stdout + result.stderr
assert 'Native MailChime menu and About diagnostic passed.' in result.stdout
print('Native MailChime menu actions, separate 720 x 430 License window, About, and Settings-close exit passed.')

result = subprocess.run([str(executable), '--diagnose-service'], capture_output=True, text=True, timeout=15)
assert result.returncode == 0 and 'Agent bundle valid: true' in result.stdout
assert 'Agent missing from app bundle' not in result.stdout
print(result.stdout.strip())
result = subprocess.run([str(executable), '--diagnose-notification'], capture_output=True, text=True, timeout=15)
assert result.returncode == 0 and 'Per-message notification diagnostic passed.' in result.stdout
print(result.stdout.strip())

source_sound = Path(__file__).resolve().parent.parent / 'Support/Notification_A.aiff'
assert (app / 'Contents/Resources/Notification_A.aiff').read_bytes() == source_sound.read_bytes(), 'Notification sound missing or changed in app bundle'
print('Bundled notification sound matches source audio.')

assert (app / 'Contents/Resources/LICENSE').read_bytes() == (Path(__file__).resolve().parent.parent / 'LICENSE').read_bytes(), 'Bundled license differs from project LICENSE'
print('Bundled LICENSE matches the project license.')

# Inspect signed entitlements as well as the on-disk bundle structure.
extension = app / 'Contents/PlugIns/MailChimeNotificationService.appex'
assert extension.is_dir(), 'Notification extension not embedded'
extension_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
assert extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.usernotifications.service'
assert extension_info['NSExtension'].get('Subsystems') == ['NSExtensionService_Subsystem'], 'Missing NSExtensionService_Subsystem in built extension Info.plist'
assert (extension / 'Contents/Resources/Notification_A.aiff').read_bytes() == source_sound.read_bytes()
for bundle in [app, extension]:
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    assert entitlements['com.apple.security.application-groups'] == [info['MailChimeAppGroup']]
    assert entitlements['keychain-access-groups'] == [info['MailChimeKeychainGroup']]
    if bundle == app:
        assert entitlements['com.apple.developer.aps-environment'] == info['MailChimeAPNsEnvironment']
        assert not entitlements.get('com.apple.security.app-sandbox', False)
    else:
        assert entitlements['com.apple.security.app-sandbox'] is True
print('Signed APNs, shared App Group/Keychain, sandboxed extension, and bundled sound passed.')

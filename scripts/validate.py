#!/usr/bin/env python3
"""Validate the native app bundle contract and removed provider/tooling boundaries."""
from pathlib import Path
import json
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
errors = []
def require(condition, message):
    if not condition:
        errors.append(message)

info = plistlib.loads((root / 'Support/Info.plist').read_bytes())
agent = plistlib.loads((root / 'Support/com.rhpt.mailchime.agent.plist').read_bytes())
require(not (root / 'Support/com.rhpt.fnm.agent.plist').exists(), 'Obsolete agent plist in Support')
require(info['CFBundleName'] == 'MailChime' and info['CFBundleDisplayName'] == 'MailChime', 'App name must be MailChime')
require(info.get('CFBundleIconFile') == 'NewAppIcon' and info.get('CFBundleIconName') == 'NewAppIcon', 'App icon must be NewAppIcon')
require((root / 'Support/NewAppIcon.icon/icon.json').is_file(), 'Missing Support/NewAppIcon.icon')
require(info['NSHumanReadableCopyright'] == '© 2026 RHPT\nReleased under the MIT License\nBased on MailBell by Marton Paulo and Samzong',
        'About copyright text mismatch')
require(info['CFBundleShortVersionString'] == '$(MARKETING_VERSION)', 'Version must use Xcode setting')
require(info['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)', 'Build must use Xcode setting')
require(agent['Label'] == 'com.rhpt.mailchime.agent', 'Agent label mismatch')
require(agent['BundleProgram'] == 'Contents/MacOS/MailChime', 'Agent executable mismatch')
require(agent['ProgramArguments'] == ['MailChime', '--agent'], 'Agent arguments mismatch')
require(agent['LimitLoadToSessionType'] == 'Aqua', 'Agent must run in the user session')
require(not any(key.startswith('SU') for key in info), 'Obsolete updater configuration')
if (root / 'AGENTS.md').is_file():
    require((root / 'AGENTS.md').stat().st_size < 24000, 'Instruction file too large')
for directory in ['Sources', 'Tests', 'Support']:
    for path in (root / directory).rglob('*'):
        if any(part.startswith('DerivedData') for part in path.parts) or path.suffix not in ['.swift', '.plist', '.xcstrings']:
            continue
        text = path.read_text()
        require(not re.search(r'gmail|google|oauth|xoauth|X-GM-|SwiftSoup|Sparkle|FlyingFox', text, re.I),
                f'Obsolete provider/dependency in {path.relative_to(root)}')
require(not (root / 'site').exists(), 'Obsolete website folder')
for path in (root / 'Sources/MailChimeKit').rglob('*.swift'):
    imports = re.findall(r'^import (\w+)', path.read_text(), re.M)
    require(all(item in ['Foundation', 'Observation', 'Synchronization', 'CoreGraphics', 'CryptoKit', 'Security', 'LocalAuthentication', 'UserNotifications', 'Darwin'] for item in imports),
            f'Platform framework in pure library: {path.name}')
catalog = json.loads((root / 'Support/Localizable.xcstrings').read_text())
for path in (root / 'Sources').rglob('*.swift'):
    for value in re.findall(r'String\(\s*localized:\s*"((?:\\.|[^"\\])*)"', path.read_text()):
        key = re.sub(r'\\\([^)]*\)', '%lld', value)
        require(key in catalog['strings'], f'Missing localized copy in {path.name}: {key}')
require(catalog['sourceLanguage'] == 'en', 'Wrong source language')
for entry in catalog['strings'].values():
    require(set(entry.get('localizations', {})) <= {'en'}, 'Unexpected locale')
project_file = root / 'MailChime.xcodeproj/project.xcproj'
if not project_file.is_file():
    project_file = root / 'MailChime.xcodeproj/project.pbxproj'
    subprocess.run(['plutil', '-lint', str(project_file)], check=True)
require(project_file.is_file(), 'Missing MailChime.xcodeproj project file')
require(not (root / 'FNM.xcodeproj').exists() and not (root / 'Mailbell.xcodeproj').exists(),
        'Obsolete Xcode project bundle still exists')
project_text = project_file.read_text()
require('XCLocalSwiftPackageReference' not in project_text, 'Self-referential local package hides Xcode project/targets')
require('"INFOPLIST_KEY_CFBundleDisplayName": "MailChime"' in project_text and 'Fastmail Notifier' not in project_text,
        'Xcode target display name must be MailChime')
require('"NewAppIcon.icon"' in project_text and '"ASSETCATALOG_COMPILER_APPICON_NAME": "NewAppIcon"' in project_text and '"AppIcon.icns"' not in project_text,
        'Xcode target must use NewAppIcon.icon as the app icon')
for target_name in ['MailChime', 'MailChimeKit', 'MailChimeTests', 'MailChimeNotificationService']:
    require(f'"{target_name}"' in project_text, f'Missing native Xcode target: {target_name}')
workspace_data = root / 'MailChime.xcodeproj/project.xcworkspace/contents.xcworkspacedata'
require(workspace_data.is_file() and 'location = "self:"' in workspace_data.read_text(),
        'Missing self reference in MailChime.xcodeproj/project.xcworkspace/contents.xcworkspacedata')
# Shared entitlement and extension contract, independent of signing availability.
app_entitlements = plistlib.loads((root / 'Support/MailChime.entitlements').read_bytes())
extension_entitlements = plistlib.loads((root / 'Support/MailChimeNotificationService.entitlements').read_bytes())
extension_info = plistlib.loads((root / 'Support/MailChimeNotificationService-Info.plist').read_bytes())
require(app_entitlements.get('com.apple.developer.aps-environment') == '$(MailChime_APS_ENVIRONMENT)', 'Missing build-specific APNs entitlement')
require('com.apple.security.app-sandbox' not in app_entitlements, 'Main app must remain unsandboxed')
require(extension_entitlements.get('com.apple.security.app-sandbox') is True, 'Extension must be sandboxed')
for entitlements in [app_entitlements, extension_entitlements]:
    require(entitlements.get('com.apple.security.application-groups') == ['$(TeamIdentifierPrefix)com.rhpt.mailchime'], 'Wrong App Group')
    require(entitlements.get('keychain-access-groups') == ['$(AppIdentifierPrefix)com.rhpt.mailchime.shared'], 'Wrong shared Keychain access group')
require(extension_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.usernotifications.service', 'Wrong extension point')
require(extension_info.get('NSExtension', {}).get('Subsystems') == ['NSExtensionService_Subsystem'], 'Missing NSExtensionService_Subsystem in extension Info.plist')
require(info.get('MailChimeAPNsEnvironment') == '$(MailChime_APS_ENVIRONMENT)', 'Missing APNs environment metadata')
require('Contents/PlugIns' in project_text and 'Embed Foundation Extensions' in project_text, 'Extension must be embedded in Contents/PlugIns')
require('MailChimeNotificationService.appex' in project_text, 'Missing extension product')
require('MailChime_APS_ENVIRONMENT[config=Debug]' in project_text and 'MailChime_APS_ENVIRONMENT[config=Release]' in project_text, 'Missing environment configuration')
require(not (root / 'Sources/MailChime/IMAP').exists(), 'Obsolete IMAP implementation remains')
require(not (root / 'Sources/MailChimeKit/IMAPProtocol.swift').exists(), 'Obsolete protocol remains')
require(not (root / 'Sources/MailChime/Service/MailChecker.swift').exists(), 'Obsolete mail worker remains')
for path in (root / 'Sources').rglob('*.swift'):
    require(not re.search(r'IMAPClient|IMAPConnection|UIDVALIDITY|intervalMinutes|Timer.scheduledTimer', path.read_text()), f'Obsolete polling code: {path}')
if errors:
    raise SystemExit('\n'.join(errors))
print('Validated project, extension, entitlements, agent, localization, and IMAP removal.')

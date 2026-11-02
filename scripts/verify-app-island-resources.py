#!/usr/bin/env python3
"""Validate the embedded native Live Activity contract in a built app, never run it."""
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
if info.get('NSSupportsLiveActivities') is not True:
    raise SystemExit('App must declare NSSupportsLiveActivities')
schemes = [scheme for item in info.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])]
if 'mobileharness' not in schemes:
    raise SystemExit('App is missing the fixed island return URL scheme')
extension = app / 'PlugIns' / 'MobileHarnessLiveActivity.appex'
metadata = plistlib.loads((extension / 'Info.plist').read_bytes())
if metadata.get('CFBundleIdentifier') != info['CFBundleIdentifier'] + '.island':
    raise SystemExit('Live Activity extension bundle identifier must be inside the host namespace')
if metadata.get('CFBundleVersion') != info.get('CFBundleVersion') or metadata.get('CFBundleShortVersionString') != info.get('CFBundleShortVersionString'):
    raise SystemExit('App and Live Activity extension versions must match')
if metadata.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
    raise SystemExit('Expected a real WidgetKit extension')
if not (extension / metadata['CFBundleExecutable']).is_file():
    raise SystemExit('Missing WidgetKit extension executable')
if list(app.rglob('Isle-LICENSE.txt')):
    raise SystemExit('Retired Isle resources remain packaged')
print('Native Live Activity verified: embedded WidgetKit executable, matching identity/version, support flag and return URL.')

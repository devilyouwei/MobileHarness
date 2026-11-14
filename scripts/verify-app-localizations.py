#!/usr/bin/env python3
"""Verify compiled application, package, and extension localizations."""
import json
import pathlib
import plistlib
import subprocess
import sys


def read_strings(path):
    return plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(path)]))


app = pathlib.Path(sys.argv[1])
source = pathlib.Path(__file__).resolve().parent.parent
permission_keys = json.loads((source / 'Config/InfoPlist.xcstrings').read_text())['strings']
extension = app / 'PlugIns/MobileHarnessLiveActivity.appex'
ui = app / 'HarnessKit_UI.bundle'
for language in ('en', 'zh-Hans'):
    region = f'{language}.lproj'
    permissions = read_strings(app / region / 'InfoPlist.strings')
    for key in permission_keys:
        if not permissions.get(key):
            raise SystemExit(f'Missing {language} permission string: {key}')
    if language == 'zh-Hans':
        ui_strings = read_strings(ui / region / 'Localizable.strings')
        if ui_strings.get('App Language') != '应用语言':
            raise SystemExit('Chinese App Language label is missing from the UI bundle')
    status = read_strings(extension / region / 'IslandStatus.strings')
    if not status.get('Status expired'):
        raise SystemExit(f'Missing {language} Live Activity status copy')

print('English and Simplified Chinese app, UI and Live Activity resources verified.')

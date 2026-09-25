#!/usr/bin/env python3
"""Validate the project's ModelKit source and target dependency boundary."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'MobileHarness/ModelKit'
FORBIDDEN = {'AgentCore', 'Agents', 'Gateway', 'Actions', 'ActionRuntime', 'Tools', 'ToolRuntime', 'PlatformKit', 'SwiftUI', 'UIKit', 'HarnessKit'}
errors = []
for folder, directories, files in os.walk(KIT):
    directories[:] = [d for d in directories if not d.startswith('.')]
    path = Path(folder)
    if 'README.md' not in files:
        errors.append(f'Missing directory README: {path.relative_to(ROOT)}')
    for name in files:
        if not name.endswith('.swift'):
            continue
        source = path / name
        for module in re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', source.read_text()):
            if module in FORBIDDEN:
                errors.append(f'Business import {module}: {source.relative_to(ROOT)}')
if (KIT / 'Package.swift').exists() or (KIT / 'Tests').exists():
    errors.append('ModelKit must use the root project package and root Tests directory')
package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=ROOT))
for target in package['targets']:
    if not target['name'].startswith('ModelKit') or target['type'] != 'regular':
        continue
    dependencies = target.get('dependencies', [])
    if target['name'] == 'ModelKit' and dependencies:
        errors.append('The base ModelKit target must have no target/product dependencies')
    for dependency in dependencies:
        kind, values = next(iter(dependency.items()))
        name = values[0]
        if kind in ('byName', 'target') and not name.startswith('ModelKit'):
            errors.append(f"{target['name']} depends on external project target {name}")
        if kind == 'product' and target['name'] != 'ModelKitMLXLanguage':
            errors.append(f"Third-party dependency outside a backend: {target['name']} -> {name}")
        if name in FORBIDDEN:
            errors.append(f"Forbidden target dependency: {target['name']} -> {name}")
    if target['name'] == 'ModelKitRuntime':
        names = [next(iter(d.values()))[0] for d in dependencies]
        if names != ['ModelKit']:
            errors.append('ModelKitRuntime must depend only on ModelKit')
if errors:
    raise SystemExit('\n'.join(errors))
print('ModelKit boundaries: source imports, target dependencies, test location and directory READMEs passed.')

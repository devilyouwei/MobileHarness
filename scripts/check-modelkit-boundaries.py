#!/usr/bin/env python3
"""Validate the project's ModelKit source and target dependency boundary."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'MobileHarness/ModelKit'
FORBIDDEN = {'AgentCore', 'Agents', 'Gateway', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'PlatformKit', 'SwiftUI', 'UIKit', 'HarnessKit', 'UI', 'AppWorkflows', 'BehaviorAssembly'}
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
        if kind == 'product' and target['name'] not in {'ModelKitMLXLanguage', 'ModelKitFluidAudio'}:
            errors.append(f"Third-party dependency outside a backend: {target['name']} -> {name}")
        if name in FORBIDDEN:
            errors.append(f"Forbidden target dependency: {target['name']} -> {name}")
    if target['name'] == 'ModelKitRuntime':
        names = [next(iter(d.values()))[0] for d in dependencies]
        if names != ['ModelKit']:
            errors.append('ModelKitRuntime must depend only on ModelKit')
# Consolidated source ownership must retain an acyclic, non-overlapping build map.
targets = {t['name']: t for t in package['targets']}
for obsolete in ('ActionRuntime', 'ToolRuntime'):
    if obsolete in targets:
        errors.append(f'Obsolete standalone target: {obsolete}')
if targets['AgentCore'].get('path') != 'MobileHarness/Agents/Core':
    errors.append('AgentCore must compile Agents/Core')
if 'Core' not in targets['Agents'].get('exclude', []):
    errors.append('Agents must exclude the separately compiled Core directory')
for name in ('Actions', 'Tools'):
    if not (ROOT / 'MobileHarness' / name / 'Runtime' / 'README.md').is_file():
        errors.append(f'Missing consolidated {name}/Runtime')
# Gateway is transport-only; AgentCore remains independent of models/platform/business.
for module, forbidden in {
    'Gateway': {'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'Agents', 'PlatformKit'},
    'AgentCore': {'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'Gateway', 'Agents', 'PlatformKit', 'SwiftUI', 'UIKit', 'CoreVideo'},
}.items():
    source_root = ROOT / 'MobileHarness' / ('Agents/Core' if module == 'AgentCore' else module)
    if not source_root.is_dir():
        errors.append(f'Missing checked source root: {source_root}')
    for source in source_root.rglob('*.swift'):
        for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
            if imported in forbidden or imported.startswith('ModelKit'):
                errors.append(f'Forbidden {module} import {imported}: {source.relative_to(ROOT)}')
    target = next(t for t in package['targets'] if t['name'] == module)
    for dependency in target.get('dependencies', []):
        name = next(iter(dependency.values()))[0]
        if name in forbidden or name.startswith('ModelKit'):
            errors.append(f'Forbidden {module} dependency: {name}')
# The unified behavior libraries expose runtime APIs to Gateway, not direct behavior calls.
for source in (ROOT / 'MobileHarness/Gateway').rglob('*.swift'):
    if re.search(r'\b(?:UIActions|SpeechPlayback|UITools|SystemTools)\b', source.read_text()):
        errors.append(f'Gateway directly uses a concrete behavior: {source.relative_to(ROOT)}')
# Agents may compute with the base ModelKit SDK, never invoke business/UI/device modules.
agent_allowed = {'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio', 'Foundation'}
for source in (ROOT / 'MobileHarness/Agents').rglob('*.swift'):
    if 'Core' in source.relative_to(ROOT / 'MobileHarness/Agents').parts:
        continue
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported not in agent_allowed:
            errors.append(f'Forbidden Agents import {imported}: {source.relative_to(ROOT)}')
agent_target = next(t for t in package['targets'] if t['name'] == 'Agents')
for dependency in agent_target.get('dependencies', []):
    name = next(iter(dependency.values()))[0]
    if name not in {'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio'}:
        errors.append(f'Forbidden Agents dependency: {name}')
# Storage core stays Foundation-only; media adapters may use the corresponding domain contracts.
storage_target = next(t for t in package['targets'] if t['name'] == 'Storage')
if storage_target.get('dependencies'):
    errors.append('Storage must have no target/product dependencies')
for source in (ROOT / 'MobileHarness/Storage').glob('*.swift'):
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported != 'Foundation':
            errors.append(f'Forbidden Storage import {imported}: {source.relative_to(ROOT)}')
# Business storage domains cannot be compiled into the generic core.
if not {'Audio', 'Chat'}.issubset(set(storage_target.get('exclude', []))):
    errors.append('Storage core must exclude business storage directories')
chat_target = targets.get('StorageChat', {})
if chat_target.get('path') != 'MobileHarness/Storage/Chat' or [next(iter(d.values()))[0] for d in chat_target.get('dependencies', [])] != ['Storage']:
    errors.append('StorageChat must compile Storage/Chat and depend only on Storage')
for source in (ROOT / 'MobileHarness/Storage/Chat').rglob('*.swift'):
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported not in {'Foundation', 'Storage'}:
            errors.append(f'Forbidden StorageChat import {imported}: {source.relative_to(ROOT)}')
for path, directories, files in os.walk(ROOT / 'MobileHarness/Storage'):
    if 'README.md' not in files:
        errors.append(f'Missing Storage directory README: {Path(path).relative_to(ROOT)}')
audio_target = next(t for t in package['targets'] if t['name'] == 'StorageAudio')
audio_dependencies = [next(iter(d.values()))[0] for d in audio_target.get('dependencies', [])]
if audio_dependencies != ['Storage', 'AgentCore', 'ModelKit']:
    errors.append('StorageAudio must depend only on Storage, AgentCore and ModelKit')
# Speech signal observation is runtime admission/logging, never a UI-command side channel.
coordinator = (ROOT / 'MobileHarness/App/Lifecycle/VoiceSessionCoordinator.swift').read_text()
observer = coordinator.split('func observeSpeech(', 1)[1].split('private func resumeListening(', 1)[0]
for field in ('voicePhase', 'presentationPhase', 'voiceStatus', 'audioLevel', 'expression', 'expressionID', 'assistantReply', 'liveTranscript'):
    if re.search(r'\b' + field + r'\s*=', observer):
        errors.append(f'Signal observer modifies UI field: {field}')
# UI is independently compiled and can consume shared values, never App services.
ui = targets.get('UI', {})
if ui.get('path') != 'MobileHarness/UI':
    errors.append('UI must compile MobileHarness/UI')
ui_dependencies = [next(iter(d.values()))[0] for d in ui.get('dependencies', [])]
if ui_dependencies != ['AgentCore', 'StorageChat']:
    errors.append('UI may depend only on shared AgentCore/StorageChat value contracts')
allowed_ui = {'Foundation', 'CoreGraphics', 'Observation', 'SwiftUI', 'UIKit', 'AgentCore', 'StorageChat'}
for source in (ROOT / 'MobileHarness/UI').rglob('*.swift'):
    content = source.read_text()
    for imported in re.findall(r'\bimport\s+(\w+)', content):
        if imported not in allowed_ui:
            errors.append(f'Forbidden UI import {imported}: {source.relative_to(ROOT)}')
    if re.search(r'\b(?:VoiceSessionCoordinator|CameraCoordinator|ApplicationRuntime|AppContainer|AppAssembly|ConversationHistoryStore|LocalDocumentStore|MemoryLeaseStore)\b', content):
        errors.append(f'UI uses a runtime/service implementation: {source.relative_to(ROOT)}')
for folder in ('App', 'UI'):
    for path, directories, files in os.walk(ROOT / 'MobileHarness' / folder):
        if 'README.md' not in files:
            errors.append(f'Missing directory README: {Path(path).relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness/App').rglob('*.swift'):
    if 'ApplicationRuntime.shared(' in source.read_text():
        errors.append(f'Hidden application runtime lookup: {source.relative_to(ROOT)}')
# Domain libraries cannot reach back into application composition or concrete services.
for root, allowed in [
    ('Actions', {'Foundation', 'Synchronization', 'AgentCore', 'StorageAudio'}),
    ('Tools', {'Foundation', 'AgentCore'}),
    ('App/Composition/Behaviors', {'AgentCore', 'Actions', 'Tools'}),
]:
    for source in (ROOT / 'MobileHarness' / root).rglob('*.swift'):
        for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
            if imported not in allowed:
                errors.append(f'Forbidden behavior-layer import {imported}: {source.relative_to(ROOT)}')
# Behavior registration belongs to domain catalogs, not individual App call sites.
behavior_target = targets.get('BehaviorAssembly', {})
if behavior_target.get('path') != 'MobileHarness/App/Composition/Behaviors':
    errors.append('BehaviorAssembly must compile the isolated composition directory')
if [next(iter(d.values()))[0] for d in behavior_target.get('dependencies', [])] != ['AgentCore', 'Actions', 'Tools']:
    errors.append('BehaviorAssembly may depend only on AgentCore, Actions and Tools')
for source in (ROOT / 'MobileHarness/App').rglob('*.swift'):
    content = source.read_text()
    if re.search(r'\b(?:ActionDefinition|ToolDefinition)\s*\(|\.registerCompletion\s*\(', content):
        errors.append(f'App contains per-function behavior registration: {source.relative_to(ROOT)}')
    if re.search(r'\b(?:UIActions|UITools|SystemTools)\.[a-z]\w*\s*\(', content):
        errors.append(f'App invokes a domain behavior helper: {source.relative_to(ROOT)}')
    if re.search(r'\bActionPath\s*\(|\.register\s*\(\s*"', content):
        errors.append(f'App contains a concrete behavior path: {source.relative_to(ROOT)}')
# Action authoring: every declared domain path has a canonical namespace and entry file.
for domain in (ROOT / 'MobileHarness/Actions').iterdir():
    if not domain.is_dir() or domain.name == 'Runtime':
        continue
    namespace = domain / (domain.name + 'Actions.swift')
    if not namespace.exists() or not re.search(r'public enum ' + domain.name + r'Actions\s*\{\s*\}', namespace.read_text()):
        errors.append(f'Missing canonical Action namespace: {domain.name}')
    for module in domain.glob('*ActionModule.swift'):
        for module_name, function in re.findall(r'ActionPath\(module: "([^"]+)", function: "([^"]+)"\)', module.read_text()):
            entry = domain / (function[0].upper() + function[1:] + '.swift')
            if module_name != domain.name or not entry.exists():
                errors.append(f'Missing canonical Action entry: {module_name}.{function}')
                continue
            pattern = r'public static func ' + function + r'\(\s*invocation: ActionInvocation,\s*using\s+'
            if not re.search(pattern, entry.read_text()):
                errors.append(f'Noncanonical Action signature: {entry.relative_to(ROOT)}')
if errors:
    raise SystemExit('\n'.join(errors))
print('ModelKit boundaries: source imports, target dependencies, test location and directory READMEs passed.')

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
    if target['name'] == 'ModelKit' and [next(iter(d.values()))[0] for d in dependencies] != ['Types']:
        errors.append('The base ModelKit target may depend only on Types')
    for dependency in dependencies:
        kind, values = next(iter(dependency.items()))
        name = values[0]
        if kind in ('byName', 'target') and not name.startswith('ModelKit') and name != 'Types':
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
for name, path in [('ActionRuntime', 'Actions/Runtime'), ('ToolRuntime', 'Tools/Runtime')]:
    if targets.get(name, {}).get('path') != 'MobileHarness/' + path or targets[name].get('dependencies'):
        errors.append(f'{name} must compile its runtime independently without dependencies')
    for source in (ROOT / 'MobileHarness' / path).rglob('*.swift'):
        if any(module not in {'Foundation', 'Synchronization'} for module in re.findall(r'\bimport\s+(\w+)', source.read_text())):
            errors.append(f'Business dependency in {name}: {source.relative_to(ROOT)}')
for name in ('Actions', 'Tools'):
    if 'Runtime' not in targets[name].get('exclude', []):
        errors.append(f'{name} must exclude independently compiled Runtime')
if targets['AgentCore'].get('path') != 'MobileHarness/Agents/Core':
    errors.append('AgentCore must compile Agents/Core')
if 'Core' not in targets['Agents'].get('exclude', []):
    errors.append('Agents must exclude the separately compiled Core directory')
for name in ('Actions', 'Tools'):
    if not (ROOT / 'MobileHarness' / name / 'Runtime' / 'README.md').is_file():
        errors.append(f'Missing consolidated {name}/Runtime')
# Gateway is transport-only; AgentCore remains independent of models/platform/business.
for module, forbidden in {
    'PlatformKit': {'Actions', 'Tools', 'Agents', 'AgentCore', 'Gateway', 'UI', 'AppWorkflows', 'BehaviorAssembly'},
    'Gateway': {'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'Agents', 'PlatformKit', 'Actions', 'Tools'},
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
if [next(iter(d.values()))[0] for d in targets['PlatformKit'].get('dependencies', [])] != ['Types']:
    errors.append('PlatformKit may depend only on shared Types')
# Device SDK must not regain choreography or Action completion policy.
for source in (ROOT / 'MobileHarness/PlatformKit/Connectivity/NexArm').glob('*.swift'):
    if re.search(r'\b(?:NexArmGesture|NexArmArmPlan|NexArmActionController|NexArmMotionPlan|NexArmSegmentTracker|NexArmMotorCompletion|NexArmMotorResult|NexArmActionError|NexArmJogPlanner|NexArmMotorReset)\b', source.read_text()):
        errors.append(f'Action policy in device SDK: {source.relative_to(ROOT)}')
# Foundation SDKs expose data/capabilities; app presentation and action policy stay above them.
for source in (ROOT / 'MobileHarness/PlatformKit').rglob('*.swift'):
    content = source.read_text()
    if re.search(r'"[^"\n]*[\u4e00-\u9fff][^"\n]*"', content):
        errors.append(f'Localized presentation string in PlatformKit: {source.relative_to(ROOT)}')
    if re.search(r'\b(?:func|var)\s+(?:discoveryOrder|displayName|performGesture|resetMotor|resetPosition)\b', content):
        errors.append(f'Business/presentation API in PlatformKit: {source.relative_to(ROOT)}')
    if 'videoGravity =' in content:
        errors.append(f'Preview layout policy in PlatformKit: {source.relative_to(ROOT)}')
# The unified behavior libraries expose runtime APIs to Gateway, not direct behavior calls.
for source in (ROOT / 'MobileHarness/Gateway').rglob('*.swift'):
    if re.search(r'\b(?:UIActions|SpeechPlayback|UITools|SystemTools|CameraTools)\b', source.read_text()):
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
if audio_dependencies != ['Storage', 'Types']:
    errors.append('StorageAudio must depend only on Storage and Types')
for source in (ROOT / 'MobileHarness/Storage/Audio').rglob('*.swift'):
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported not in {'Foundation', 'Storage', 'Types'}:
            errors.append(f'Forbidden StorageAudio import {imported}: {source.relative_to(ROOT)}')
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
    ('Actions', {'Foundation', 'Synchronization', 'PlatformKit', 'ActionRuntime'}),
    ('Tools', {'Foundation', 'ToolRuntime'}),
    ('App/Composition/Behaviors', {'Actions', 'Tools', 'ActionRuntime', 'ToolRuntime'}),
]:
    for source in (ROOT / 'MobileHarness' / root).rglob('*.swift'):
        for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
            if imported not in allowed:
                errors.append(f'Forbidden behavior-layer import {imported}: {source.relative_to(ROOT)}')
# Behavior registration belongs to domain catalogs, not individual App call sites.
behavior_target = targets.get('BehaviorAssembly', {})
if behavior_target.get('path') != 'MobileHarness/App/Composition/Behaviors':
    errors.append('BehaviorAssembly must compile the isolated composition directory')
if [next(iter(d.values()))[0] for d in behavior_target.get('dependencies', [])] != ['Actions', 'Tools', 'ActionRuntime', 'ToolRuntime']:
    errors.append('BehaviorAssembly may depend only on behavior domains and execution runtimes')
for source in (ROOT / 'MobileHarness/App').rglob('*.swift'):
    content = source.read_text()
    if re.search(r'\b(?:ActionDefinition|ToolDefinition)\s*\(|\.registerCompletion\s*\(', content):
        errors.append(f'App contains per-function behavior registration: {source.relative_to(ROOT)}')
    if re.search(r'\b(?:UIActions|UITools|SystemTools|CameraTools)\.[a-z]\w*\s*\(', content):
        errors.append(f'App invokes a domain behavior helper: {source.relative_to(ROOT)}')
    if re.search(r'\bActionPath\s*\(|\.register\s*\(\s*"', content):
        errors.append(f'App contains a concrete behavior path: {source.relative_to(ROOT)}')
# Historical polling controllers must not re-enter production Action sources.
controller = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmActionController.swift').read_text()
if re.search(r'public func (?:nudgeWrist|shakeBase)\(', controller):
    errors.append('Retired NexArm polling diagnostics belong in root Tests')
for source in (ROOT / 'MobileHarness/Actions').rglob('*.swift'):
    if 'NexArmLegacy' in source.read_text():
        errors.append(f'Production Action imports a historical test algorithm: {source.relative_to(ROOT)}')
# Action authoring: cohesive entry files, recursively discovered support registrations.
# This is a source convention check; Swift and assembly tests validate semantic binding.
actions_root = ROOT / 'MobileHarness/Actions'
for folder, directories, files in os.walk(actions_root):
    if 'README.md' not in files:
        errors.append(f'Missing Action directory README: {Path(folder).relative_to(ROOT)}')
for domain in actions_root.iterdir():
    if not domain.is_dir() or domain.name in {'Runtime', 'Contracts'}:
        continue
    namespace_name = domain.name + 'Actions'
    namespace = domain / (namespace_name + '.swift')
    if not namespace.exists() or not re.search(r'public enum ' + namespace_name + r'\s*\{', namespace.read_text()):
        errors.append(f'Missing canonical Action namespace: {domain.name}')
    sources = {source: source.read_text() for source in domain.rglob('*.swift')}
    entries = {}
    for source, content in sources.items():
        # Only direct domain entry files participate; support types are not callable entries.
        if source.parent != domain:
            continue
        if not re.search(r'(?:public enum|extension) ' + namespace_name + r'\s*\{', content):
            errors.append(f'Action entry file lacks domain namespace: {source.relative_to(ROOT)}')
        for function in re.findall(r'public static func (\w+)\(\s*invocation: ActionInvocation,\s*using\s+', content):
            entries.setdefault(function, []).append(source)
    for source, content in sources.items():
        for module_name, function in re.findall(r'ActionPath\(module: "([^"]+)", function: "([^"]+)"\)', content):
            if source.parent != domain / 'Support':
                errors.append(f'Action registration must live in domain Support: {source.relative_to(ROOT)}')
            if module_name != domain.name or len(entries.get(function, [])) != 1:
                errors.append(f'Missing or ambiguous canonical Action entry: {module_name}.{function}')
    # Metadata is attached to canonical entries; binding factories still belong in Support.
    for source, content in sources.items():
        for module_name in re.findall(r'@Action\(\s*module: "([^"]+)"', content):
            if source.parent != domain or module_name != domain.name:
                errors.append(f'Invalid Action macro owner: {source.relative_to(ROOT)}')
        for function in re.findall(namespace_name + r'\.(\w+)Definition\(', content):
            if source.parent != domain / 'Support' or len(entries.get(function, [])) != 1:
                errors.append(f'Invalid Action macro binding: {source.relative_to(ROOT)}: {function}')
# Tool authoring uses the same domain/Support boundary without imposing Action signatures.
tools_root = ROOT / 'MobileHarness/Tools'
for folder, directories, files in os.walk(tools_root):
    if 'README.md' not in files:
        errors.append(f'Missing Tool directory README: {Path(folder).relative_to(ROOT)}')
for domain in tools_root.iterdir():
    if not domain.is_dir() or domain.name in {'Runtime', 'Contracts'}:
        continue
    namespace_name = domain.name + 'Tools'
    namespace = domain / (namespace_name + '.swift')
    if not namespace.exists() or not re.search(r'public enum ' + namespace_name + r'\s*\{', namespace.read_text()):
        errors.append(f'Missing canonical Tool namespace: {domain.name}')
    sources = {source: source.read_text() for source in domain.rglob('*.swift')}
    entries = {}
    for source, content in sources.items():
        if source.parent != domain:
            continue
        if not re.search(r'(?:public enum|extension) ' + namespace_name + r'\s*\{', content):
            errors.append(f'Tool entry file lacks domain namespace: {source.relative_to(ROOT)}')
        for function in re.findall(r'public static func (\w+)\(', content):
            entries.setdefault(function, []).append(source)
    for source, content in sources.items():
        for path in re.findall(r'ToolDefinition\(\s*path: "([^"]+)"', content):
            if source.parent != domain / 'Support':
                errors.append(f'Tool registration must live in domain Support: {source.relative_to(ROOT)}')
            # Preserve the original System path; new domains use qualified names.
            if path == 'runtimeInfo':
                module, function = 'System', 'runtimeInfo'
            elif '.' in path:
                module, function = path.rsplit('.', 1)
            else:
                module, function = '', path
            if module != domain.name or len(entries.get(function, [])) != 1:
                errors.append(f'Missing or ambiguous canonical Tool entry: {path}')

    for source, content in sources.items():
        for function in re.findall(namespace_name + r'\.(\w+)Definition\(', content):
            if source.parent != domain / 'Support' or len(entries.get(function, [])) != 1:
                errors.append(f'Invalid Tool macro binding: {source.relative_to(ROOT)}: {function}')
# Compile-time generation must never acquire business/runtime dependencies.
macro = targets.get('BehaviorDefinitions')
if macro is None or macro['type'] != 'macro' or macro.get('path') != 'Macros/BehaviorDefinitions':
    errors.append('BehaviorDefinitions must remain a compile-time macro target')
elif any(next(iter(d.values()))[0] not in {'SwiftCompilerPlugin', 'SwiftSyntax', 'SwiftSyntaxBuilder', 'SwiftSyntaxMacros'} for d in macro.get('dependencies', [])):
    errors.append('BehaviorDefinitions may depend only on SwiftSyntax compiler libraries')

for module in ('Actions', 'Tools'):
    dependency_names = {next(iter(d.values()))[0] for d in targets[module].get('dependencies', [])}
    forbidden = {'AgentCore', 'Agents', 'Gateway', 'UI', 'AppWorkflows', 'BehaviorAssembly', 'StorageAudio', 'Tools' if module == 'Actions' else 'Actions'}
    if dependency_names & forbidden:
        errors.append(f'{module} has reverse execution dependencies: {dependency_names & forbidden}')

# Shared Types values cannot regain model, Agent or device ownership.
if targets['Types']['path'] != 'MobileHarness/Types' or 'AudioTypes' in targets:
    errors.append('Shared values must compile once under the category-based Types target')
if targets['Types'].get('dependencies'):
    errors.append('Types must have no dependencies')
for source in (ROOT / 'MobileHarness/Types').rglob('*.swift'):
    if any(module != 'Foundation' for module in re.findall(r'\bimport\s+(\w+)', source.read_text())):
        errors.append(f'Forbidden Types import: {source.relative_to(ROOT)}')
workflow_boundaries = {
    'Settings': ('AppSettingsWorkflow', {'UI', 'Storage'}),
    'History': ('AppHistoryWorkflow', {'UI', 'StorageChat'}),
    'Bluetooth': ('AppBluetoothWorkflow', {'UI', 'AgentCore', 'Storage', 'Actions', 'ActionRuntime', 'PlatformKit'}),
    'Speech': ('AppSpeechPlayback', {'ActionRuntime', 'StorageAudio'}),
    'Presentation': ('AppPresentationWorkflow', {'UI', 'AgentCore', 'ActionRuntime', 'ToolRuntime'}),
    'Diagnostics': ('AppDiagnosticWorkflow', {'UI', 'ModelKit', 'PlatformKit'}),
}
for folder, (target, allowed) in workflow_boundaries.items():
    deps = {next(iter(d.values()))[0] for d in targets[target].get('dependencies', [])}
    if deps != allowed:
        errors.append(f'Unexpected {target} dependencies: {deps}')
    for source in (ROOT / 'MobileHarness/App/Workflows' / folder).glob('*.swift'):
        imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
        if imports - allowed - {'Foundation', 'Synchronization', 'Security', 'AVFAudio', 'UIKit'}:
            errors.append(f'Unexpected workflow import: {source.relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness/App/Lifecycle').glob('*.swift'):
    if 'ApplicationRuntime' in source.read_text():
        errors.append(f'Lifecycle depends on whole application runtime: {source.relative_to(ROOT)}')
# Tracking rest/angle and speed policy must stay with Action-side motion ownership.
for source in (ROOT / 'MobileHarness/PlatformKit').rglob('*.swift'):
    if re.search(r'\bNexArmJointCommand\b|\bfunc\s+aim\s*\(', source.read_text()):
        errors.append(f'Tracking aim business policy in PlatformKit: {source.relative_to(ROOT)}')
if not (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmJointCommand.swift').is_file():
    errors.append('Tracking aim mapping must remain in Actions/NexArm/Support')
# Check the full declared project graph, not only selected architectural edges.
visiting, visited = set(), set()
def visit(name):
    if name in visiting:
        errors.append(f'Cyclic target dependency at {name}')
        return
    if name in visited:
        return
    visiting.add(name)
    for dependency in targets[name].get('dependencies', []):
        kind, values = next(iter(dependency.items()))
        if kind in {'byName', 'target'} and values[0] in targets:
            visit(values[0])
    visiting.remove(name)
    visited.add(name)
for name in targets:
    visit(name)
if errors:
    raise SystemExit('\n'.join(errors))
print('ModelKit boundaries: source imports, target dependencies, test location and directory READMEs passed.')

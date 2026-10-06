#!/usr/bin/env python3
"""Validate the project's ModelKit source and target dependency boundary."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'MobileHarness/ModelKit'
FORBIDDEN = {'AgentCore', 'Agents', 'Gateway', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'PlatformKit', 'SwiftUI', 'UIKit', 'HarnessKit', 'UI', 'AppWorkflows', 'BehaviorAssembly', 'Types'}
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
        errors.append('The base ModelKit target must have no project/product dependencies')
    for dependency in dependencies:
        kind, values = next(iter(dependency.items()))
        name = values[0]
        if kind in ('byName', 'target') and not name.startswith('ModelKit'):
            errors.append(f"{target['name']} depends on external project target {name}")
        if kind == 'product' and target['name'] not in {'ModelKitCoreAI', 'ModelKitFluidAudio', 'ModelKitHub'}:
            errors.append(f"Third-party dependency outside a backend: {target['name']} -> {name}")
        if name in FORBIDDEN:
            errors.append(f"Forbidden target dependency: {target['name']} -> {name}")
    if target['name'] == 'ModelKitRuntime':
        names = [next(iter(d.values()))[0] for d in dependencies]
        if names != ['ModelKit']:
            errors.append('ModelKitRuntime must depend only on ModelKit')
hub_target = next(t for t in package['targets'] if t['name'] == 'ModelKitHub')
if {next(iter(d.values()))[0] for d in hub_target['dependencies']} != {'ModelKitRuntime', 'HuggingFace'}:
    errors.append('ModelKitHub must depend only on Management contracts and the concrete Hub SDK')
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
    'PlatformKit': {'Types', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'Agents', 'AgentCore', 'Gateway', 'UI', 'AppWorkflows', 'BehaviorAssembly'},
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
if [next(iter(d.values()))[0] for d in targets['PlatformKit'].get('dependencies', [])] != []:
    errors.append('PlatformKit must have no project/product dependencies')
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
agent_allowed = {'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio', 'PlatformKit', 'Foundation'}
for source in (ROOT / 'MobileHarness/Agents').rglob('*.swift'):
    if 'Core' in source.relative_to(ROOT / 'MobileHarness/Agents').parts:
        continue
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported not in agent_allowed:
            errors.append(f'Forbidden Agents import {imported}: {source.relative_to(ROOT)}')
agent_target = next(t for t in package['targets'] if t['name'] == 'Agents')
for dependency in agent_target.get('dependencies', []):
    name = next(iter(dependency.values()))[0]
    if name not in {'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio', 'PlatformKit'}:
        errors.append(f'Forbidden Agents dependency: {name}')
# Storage owns its values/functions; domain targets may use only the internal core.
storage_target = next(t for t in package['targets'] if t['name'] == 'Storage')
if storage_target.get('dependencies'):
    errors.append('Storage must have no target/product dependencies')
for source in (ROOT / 'MobileHarness/Storage').rglob('*.swift'):
    if source.relative_to(ROOT / 'MobileHarness/Storage').parts[0] in {'Audio', 'Chat'}:
        continue
    for imported in re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', source.read_text()):
        if imported != 'Foundation':
            errors.append(f'Forbidden Storage import {imported}: {source.relative_to(ROOT)}')
# Business storage domains cannot be compiled into the generic core.
if not {'Audio', 'Chat'}.issubset(set(storage_target.get('exclude', []))):
    errors.append('Storage core must exclude business storage directories')
chat_target = targets.get('StorageChat', {})
if chat_target.get('path') != 'MobileHarness/Storage/Chat' or [next(iter(d.values()))[0] for d in chat_target.get('dependencies', [])] != ['Storage']:
    errors.append('StorageChat must compile Storage/Chat and depend only on Storage')
for source in (ROOT / 'MobileHarness/Storage/Chat').rglob('*.swift'):
    for imported in re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', source.read_text()):
        if imported not in {'Foundation', 'Storage'}:
            errors.append(f'Forbidden StorageChat import {imported}: {source.relative_to(ROOT)}')
for path, directories, files in os.walk(ROOT / 'MobileHarness/Storage'):
    if 'README.md' not in files:
        errors.append(f'Missing Storage directory README: {Path(path).relative_to(ROOT)}')
audio_target = next(t for t in package['targets'] if t['name'] == 'StorageAudio')
audio_dependencies = [next(iter(d.values()))[0] for d in audio_target.get('dependencies', [])]
if audio_dependencies != ['Storage']:
    errors.append('StorageAudio must depend only on Storage')
for source in (ROOT / 'MobileHarness/Storage/Audio').rglob('*.swift'):
    for imported in re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', source.read_text()):
        if imported not in {'Foundation', 'Storage'}:
            errors.append(f'Forbidden StorageAudio import {imported}: {source.relative_to(ROOT)}')
# Storage retains data; business context, producer policy and wording belong to consumers.
for source in (ROOT / 'MobileHarness/Storage').rglob('*.swift'):
    text = source.read_text()
    if re.search(r'\b(?:LocalizedError|errorDescription|synthesisTimedOut)\b', text):
        errors.append(f'Storage contains presentation or synthesis policy: {source.relative_to(ROOT)}')
    if any(word in text for word in ('新对话', '待生成标题')):
        errors.append(f'Storage contains localized title fallback: {source.relative_to(ROOT)}')
chat_source = (ROOT / 'MobileHarness/Storage/Chat/ConversationHistory.swift').read_text()
if re.search(r'\.suffix\(10\)|public var title:', chat_source):
    errors.append('StorageChat must not select model context or presentation titles')
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
if ui_dependencies != ['StorageChat']:
    errors.append('UI may depend only on StorageChat values and its own presentation contracts')
allowed_ui = {'Foundation', 'CoreGraphics', 'Observation', 'SwiftUI', 'UIKit', 'StorageChat'}
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
            history_storage = (root == 'Tools' and source.relative_to(ROOT / 'MobileHarness/Tools').parts[0] == 'History' and imported == 'StorageChat')
            if imported not in allowed and not history_storage:
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

# Retired shared-value module must not return through targets or imports.
if 'Types' in targets or 'AudioTypes' in targets or (ROOT / 'MobileHarness/Types').exists():
    errors.append('Types is retired; contracts belong to their owning modules')
for source in list((ROOT / 'MobileHarness').rglob('*.swift')) + list((ROOT / 'Tests').rglob('*.swift')):
    if re.search(r'\bimport\s+Types\b', source.read_text()):
        errors.append(f'Retired Types import: {source.relative_to(ROOT)}')
workflow_boundaries = {
    'Settings': ('AppSettingsWorkflow', {'UI', 'Storage'}),
    'History': ('AppHistoryWorkflow', {'UI', 'StorageChat', 'AgentCore', 'Agents', 'Gateway', 'Tools', 'ToolRuntime'}),
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
# History transport is a narrow staged exception, not blanket feature policy access.
history_source_boundaries = {
    'ConversationHistoryWorkflow.swift': {'UI', 'StorageChat'},
    'HistoryIntentRuntime.swift': {'AgentCore', 'Agents', 'Gateway'},
    'HistoryPresentationAdapter.swift': {'UI', 'StorageChat', 'Tools', 'ToolRuntime'},
}
for name, allowed in history_source_boundaries.items():
    source = ROOT / 'MobileHarness/App/Workflows/History' / name
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - allowed - {'Foundation'}:
        errors.append(f'Unexpected history role import: {source.relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness/Agents/ConversationMemory').glob('*.swift'):
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - {'Foundation', 'AgentCore'}:
        errors.append(f'ConversationMemory must emit capabilities rather than call services: {source.relative_to(ROOT)}')
# Discovery/connection presentation must not consume device Action diagnostics.
bluetooth_view = (ROOT / 'MobileHarness/UI/Settings/BluetoothSettingsView.swift').read_text()
discovery_view = bluetooth_view.split('private struct BluetoothArmDetailView', 1)[0]
if re.search(r'\bstate\.(?:error|notice|incidents|motionStatus|executing|controlReady|controlValidated)\b', discovery_view):
    errors.append('Bluetooth discovery/connection UI consumes Action diagnostics or execution state')
# Device recovery must not acquire voice/session or scheduler cleanup.
bluetooth_sources = (ROOT / 'MobileHarness/App/Workflows/Bluetooth').glob('*.swift')
for source in bluetooth_sources:
    if re.search(r'\b(?:quiesce|stopVoice|beginSettingsChange|synchronizeAgentControl|ChannelScheduler)\b', source.read_text()):
        errors.append(f'Bluetooth recovery depends on session/scheduler policy: {source.relative_to(ROOT)}')
bluetooth_workflow = (ROOT / 'MobileHarness/App/Workflows/Bluetooth/BluetoothWorkflow.swift').read_text()
disconnect_body = bluetooth_workflow.split('private func disconnect(', 1)[1].split('public func forget(', 1)[0]
if 'motion?.cancel()' in disconnect_body or 'movement.value' in disconnect_body:
    errors.append('Native disconnect must not cancel or join finite Agent Actions')
runtime = (ROOT / 'MobileHarness/App/Composition/ApplicationRuntime.swift').read_text()
if 'synchronizeAgentControl' in runtime or 'initiallyUnavailableResources' in runtime:
    errors.append('Bluetooth recovery must not bind scheduler admission or queue cleanup')
# Resource takeover is generic execution policy; concrete tracking priority stays in composition.
resource_coordinator = (ROOT / 'MobileHarness/Gateway/Output/Resources/ResourceCoordinator.swift').read_text()
if re.search(r'\.(?:assistant|photographer)\b|nexarm\.', resource_coordinator):
    errors.append('ResourceCoordinator contains concrete Agent/device takeover policy')
if re.search(r'\bfaulted\b|func recover\(', resource_coordinator):
    errors.append('Resource ownership must not retain device-health fault/recover states')
if 'case unlocked' not in resource_coordinator or 'case locked(ExecutionOwner?)' not in resource_coordinator:
    errors.append('Resource snapshots must expose unlocked/locked ownership')
if 'ResourceExecutionPermit' not in resource_coordinator or 'validateUse' not in resource_coordinator:
    errors.append('Resource execution must bind revocable per-use validation')
if 'validateAgentWriter' not in bluetooth_workflow or 'ResourceExecutionContext.permit' not in bluetooth_workflow:
    errors.append('Agent motor effects must validate inherited resource execution authority')
camera_ownership = (ROOT / 'MobileHarness/App/Lifecycle/CameraCoordinator.swift').read_text()
if '.faulted' in camera_ownership or 'resources.recover' in camera_ownership or 'recoverRequested' in camera_ownership:
    errors.append('Camera retry must acquire actual ownership without resource-fault recovery')
if 'preempts: [.assistant: [.photographer]]' not in runtime or 'executionGroup:' not in runtime:
    errors.append('Composition must configure Assistant-over-Photographer shared-writer takeover')
if 'trackingInputAvailable' not in runtime or '[weak photographer]' not in runtime or 'hasFreshPose()' not in runtime:
    errors.append('Tracking freshness must be bound to the current Photographer without retaining its lifetime')
assembly = (ROOT / 'MobileHarness/App/Composition/AppAssembly.swift').read_text()
bluetooth_binding = assembly.split('lazy var bluetooth = BluetoothWorkflow(', 1)[1].split('lazy var camera', 1)[0]
if re.search(r'\b(?:lifecycle|quiesce|stopVoice|beginSettingsChange)\b', bluetooth_binding):
    errors.append('Bluetooth composition must not bind whole voice/session cleanup')
for source in (ROOT / 'MobileHarness/App/Lifecycle').glob('*.swift'):
    if 'ApplicationRuntime' in source.read_text():
        errors.append(f'Lifecycle depends on whole application runtime: {source.relative_to(ROOT)}')
    if re.search(r'\bPhotographerAgent\s*\(', source.read_text()):
        errors.append(f'Lifecycle constructs Photographer instead of an injected factory: {source.relative_to(ROOT)}')
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
# History uses only a foundational journal; runtime/assembly remain independent.
tool_dependencies = {next(iter(d.values()))[0] for d in targets['Tools'].get('dependencies', [])}
if 'StorageChat' not in tool_dependencies:
    errors.append('History Tools require the explicit StorageChat dependency')
for source in (ROOT / 'MobileHarness/Tools/History').rglob('*.swift'):
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - {'Foundation', 'ToolRuntime', 'StorageChat'}:
        errors.append(f'History Tools have non-foundational imports: {source.relative_to(ROOT)}')
# Feature-specific presentation contracts must not return to Agent infrastructure.
if (ROOT / "MobileHarness/Agents/Core/Output/PoseOverlay.swift").exists():
    errors.append("PoseOverlay belongs to UI/Camera, not AgentCore")

# Core owns generic contracts, never built-in application Agents or speech policy.
core_dependencies = [next(iter(d.values()))[0] for d in targets['AgentCore'].get('dependencies', [])]
if core_dependencies != []:
    errors.append('AgentCore must have zero project dependencies')
core_identity = (ROOT / 'MobileHarness/Agents/Core/AgentID.swift').read_text()
if 'public static let' in core_identity:
    errors.append('Concrete application Agent identities belong to Agents')
core_prompt = (ROOT / 'MobileHarness/Agents/Core/Capability/CapabilityContextBuilder.swift').read_text()
if any(marker in core_prompt for marker in ('speechChannel', 'audio playback', 'Speak-then-act')):
    errors.append('Assistant speech policy must not enter AgentCore prompt construction')
for source in (ROOT / 'MobileHarness/Agents/Core').rglob('*.swift'):
    if re.search(r'public (?:struct|enum) (?:PoseObservation|SpeechPhase|SpeechSynthesisInput)\b', source.read_text()):
        errors.append('Agent communication domain values belong to Agents/Communication')

# Generic communication infrastructure must not regain application domain schemas or camera samples.
for directory in ('MobileHarness/Agents/Core', 'MobileHarness/Gateway'):
    for source in (ROOT / directory).rglob('*.swift'):
        content = source.read_text()
        if any(marker in content for marker in ('"speech.', '"vision.', '"sound.', '"phone.', 'gray64', 'PerceptionMessage')):
            errors.append(f'Domain communication policy in generic infrastructure: {source.relative_to(ROOT)}')
if (ROOT / 'MobileHarness/Agents/Core/Communication/PerceptionInput.swift').exists() or (ROOT / 'MobileHarness/Agents/Core/ImageInput.swift').exists():
    errors.append('Domain/media input definitions must not return to Core')
if 'public enum AgentMessage' in (ROOT / 'MobileHarness/Agents/Core/Communication/AgentMessaging.swift').read_text():
    errors.append('Core AgentMessage must remain generic, not a closed business enum')

# Core resources/results and lexical parsing must remain business-neutral.
for source in [*(ROOT / 'MobileHarness/Agents/Core').rglob('*.swift'), *(ROOT / 'MobileHarness/Gateway').rglob('*.swift')]:
    content = source.read_text()
    if any(marker in content for marker in ('"camera.capture"', 'cameraCapture', 'public let motor: Int', 'public let target: Int', 'public let observed: Int', 'case targetNotReached', 'case invalidPose', 'controlNotReady', 'feedbackTimeout')):
        errors.append(f'Concrete resource/result policy in generic infrastructure: {source.relative_to(ROOT)}')
sentence_source = (ROOT / 'MobileHarness/Agents/Core/Generation/SentenceFunctionBuffer.swift').read_text()
if re.search(r'containsHanzi\s*\?\s*60\s*:\s*120', sentence_source):
    errors.append('Assistant soft text limits must not be fixed in Core')

# Speech helpers own perception only, independently of Agent transport/presentation.
speech_root = ROOT / 'MobileHarness/Agents/SpeechPerception'
for name in ('VoiceActivitySegmenter', 'SpeechBoundaryPolicy', 'SpeechRecognitionTurn', 'TranscriptAccumulator'):
    source = speech_root / f'{name}.swift'
    if not source.is_file():
        errors.append(f'Missing speech helper: {name}')
        continue
    imports = re.findall(r'^import (\w+)', source.read_text(), re.MULTILINE)
    if set(imports) - {'Foundation', 'ModelKit'}:
        errors.append(f'{name} must not import transport, UI or device modules')
if (speech_root / 'LiveSpeechInput.swift').exists():
    errors.append('Obsolete LiveSpeechInput must not duplicate SpeechRecognitionTurn')

sound_estimator = ROOT / 'MobileHarness/Agents/SpeechPerception/SoundSourceEstimator.swift'
if not sound_estimator.exists() or set(re.findall(r'^import (\w+)', sound_estimator.read_text(), re.MULTILINE)) - {'Foundation'}:
    errors.append('SoundSourceEstimator must remain pure Foundation-only Agent policy')

# Settings diagnostics delegates whole session work to Lifecycle; never duplicate capture or DSP here.
audio_workflow = ROOT / 'MobileHarness/App/Workflows/Diagnostics/AudioDetectionWorkflow.swift'
if audio_workflow.exists() and re.search(
    r'\b(?:SpeechPerceptionAgent|SoundSourceEstimator|StreamingMonoPCMResampler|AppleAudioIO|InputGateway|OutputGateway)\s*\(',
    audio_workflow.read_text(),
):
    errors.append('AudioDetectionWorkflow must use an injected whole endpoint, not construct capture/Agent/DSP services')
audio_context = ROOT / 'MobileHarness/PlatformKit/Audio/AudioCaptureContext.swift'
if audio_context.exists() and re.findall(r'^import (\w+)', audio_context.read_text(), re.MULTILINE):
    errors.append('AudioCaptureContext must remain an independent native SDK fact value')

if errors:
    raise SystemExit('\n'.join(errors))
print('ModelKit boundaries: source imports, target dependencies, test location and directory READMEs passed.')
# Runtime model catalog is the only model payload staged into either App variant.
model_catalog = ROOT / 'MobileHarness/Resources/Models/model-catalog.json'
if not model_catalog.is_file():
    raise SystemExit('Missing runtime model catalog')
catalog = json.loads(model_catalog.read_text())
if catalog.get('schemaVersion') != 2 or len(catalog.get('packages', [])) != 5:
    raise SystemExit('Invalid production model catalog')
for entry in catalog['packages']:
    source = entry['source']
    if 'files' in entry or not entry.get('requiredFiles'):
        raise SystemExit('Catalog must declare sources and required files, not resolved file manifests')
    if source['kind'] == 'huggingface':
        if not source.get('repoId') or not source.get('allowPatterns') or 'url' in source or 'sha256' in source:
            raise SystemExit('Invalid declarative Hub source')
    elif source['kind'] != 'urlArchive' or not source.get('url'):
        raise SystemExit('Invalid archive source')
for platform in ('iphoneos', 'iphonesimulator'):
    content = (ROOT / f'Config/Voice-Models-{platform}-Inputs.xcfilelist').read_text()
    model_inputs = [line for line in content.splitlines() if '/Resources/Models/' in line]
    if model_inputs != ['$(SRCROOT)/MobileHarness/Resources/Models/model-catalog.json']:
        raise SystemExit('App staging must not depend on model weights')
print('Model resources: declarative catalog and metadata-only App staging passed.')

# SDK contracts must be owned by the SDK, never aliases or re-exported application values.
for directory in ('ModelKit', 'PlatformKit'):
    for source in (ROOT / 'MobileHarness' / directory).rglob('*.swift'):
        if re.search(r'@_exported\s+import\s+Types|\bTypes\.', source.read_text()):
            raise SystemExit(f'SDK exports application values: {source.relative_to(ROOT)}')
if (ROOT / 'MobileHarness/Types/Audio/MicrophoneFrame.swift').exists():
    raise SystemExit('MicrophoneFrame must be owned by PlatformKit')
for source in list((ROOT / 'MobileHarness/App/Lifecycle').glob('*.swift')) + [ROOT / 'MobileHarness/App/Adapters/MediaInputAdapter.swift']:
    if re.search(r'\bImageFrame\s*\(|\bStreamingMonoPCMResampler\s*\(', source.read_text()):
        raise SystemExit(f'Model input preparation belongs to the calling Agent: {source.relative_to(ROOT)}')
if 'resolveImage:' in (ROOT / 'MobileHarness/App/Composition/AppAssembly.swift').read_text():
    raise SystemExit('App must not inject model image conversion into VisionPerception')
print('SDK-owned values and caller-owned model input adaptation passed.')

# Generic input contracts cannot own business Agent messages.
domain_names = {'SpeechPhase', 'SpeechSynthesisInput', 'SpeechValidationError', 'PoseObservation', 'VisionValidationError'}
for source in (ROOT / 'MobileHarness/Agents/Core/Input').rglob('*.swift'):
    declared = set(re.findall(r'\b(?:struct|enum|protocol|typealias)\s+(\w+)', source.read_text()))
    if declared & domain_names:
        raise SystemExit(f'Agent-domain value in generic input contracts: {source.relative_to(ROOT)}')
for name, filename in [('SpeechPhase', 'SpeechValues.swift'), ('SpeechSynthesisInput', 'SpeechValues.swift'), ('PoseObservation', 'PoseObservation.swift')]:
    source = ROOT / 'MobileHarness/Agents/Communication' / filename
    if not source.is_file() or not re.search(r'public (?:struct|enum) ' + name + r'\b', source.read_text()):
        raise SystemExit(f'Missing Agent-owned domain value: {name}')
if re.search(r'\b(?:outOfOrder|wrongSession)\b', (ROOT / 'MobileHarness/Agents/Core/Input/ImageInput.swift').read_text()):
    raise SystemExit('Image transport values must not own receiver ordering/session policy')
print('Agent-domain values and transport/presentation ownership passed.')

if not (ROOT / "MobileHarness/UI/Camera/PoseOverlay.swift").is_file():
    raise SystemExit("Missing UI-owned PoseOverlay")

for filename, names in [('AudioInput.swift', {'AudioInput', 'AudioValidationError'}), ('ImageInput.swift', {'ImageInput', 'ImageAttachment', 'ImageInputError'})]:
    source = ROOT / 'MobileHarness/Agents/Core/Input' / filename
    declarations = set(re.findall(r'public (?:struct|enum|protocol) (\w+)', source.read_text()))
    if not names <= declarations:
        raise SystemExit(f'Missing generic input contracts in {filename}')
    if set(re.findall(r'\bimport\s+(\w+)', source.read_text())) - {'Foundation'}:
        raise SystemExit(f'Input contracts must import Foundation only: {filename}')
for source in (ROOT / 'MobileHarness/Agents').rglob('*.swift'):
    if re.search(r'\b(?:struct|enum|typealias)\s+PoseOverlay\b', source.read_text()):
        raise SystemExit(f'Presentation value belongs to UI: {source.relative_to(ROOT)}')
print('Retired Types and module-owned input/presentation contracts passed.')

# SDK failures carry diagnostics; localized presentation belongs to consumers.
for source in KIT.rglob('*.swift'):
    content = source.read_text()
    if re.search(r'(?:reason:\s*|CapabilityError\.(?:unavailable|invalidRequest)\(\s*)"[^"\n]*[\u4e00-\u9fff]', content):
        raise SystemExit(f'Localized capability diagnostic in ModelKit: {source.relative_to(ROOT)}')
print('ModelKit diagnostics remain independent of localized presentation.')

# Execution Runtime must not regain concrete resources or device classification.
for directory in ('Actions/Runtime', 'Tools/Runtime'):
    for source in (ROOT / 'MobileHarness' / directory).rglob('*.swift'):
        content = source.read_text()
        if any(marker in content for marker in ('cameraCapture', '"camera.capture"', 'invalidPose', 'controlNotReady', 'feedbackTimeout', 'completionTimeout', 'feedbackLost', 'targetNotReached', 'sendingFailed')):
            raise SystemExit(f'Domain vocabulary in execution Runtime: {source.relative_to(ROOT)}')
print('Execution Runtime uses generic resources and producer-owned failure classification.')

# Manual submission is asynchronous App ownership, not an alternate timer-based Action executor.
manual_workflow = (ROOT / 'MobileHarness/App/Workflows/Bluetooth/BluetoothWorkflow.swift').read_text()
manual_section = manual_workflow.split('public func tryAction', 1)[1].split('private func joinCancelledControl', 1)[0]
if 'controller.performPlan' not in manual_section or 'plan.submit' in manual_section or 'link.sendLive' in manual_section:
    raise SystemExit('Settings presets must reuse Actions segment-feedback execution.')
plan_source = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmMotionPlan.swift').read_text()
if 'Task.sleep' in plan_source:
    raise SystemExit('Motion recipes must not implement nominal-frame playback sleeps.')
print('Settings presets reuse Actions segment feedback under cancellable App ownership.')

connect_source = manual_workflow.split('public func connect', 1)[1].split('public func disconnect', 1)[0]
if any(probe in connect_source for probe in ('verifyCompatibility(', 'prepareArmControl(', 'indicateConnection(', 'readState(')):
    raise SystemExit('App BLE connection must use passive feedback without active probes.')
print('App BLE connection uses native subscription and passive feedback.')

# Native diagnostics and execution results have independent owners and effects.
execution_section = manual_workflow.split('public func tryAction', 1)[1]
if any(marker in execution_section for marker in ('recordIncident(', 'appendIncident(', 'recordConnectionEvent(', 'recordLifecycleEvent(', 'recordRecoveryEvent(', 'requestRecovery(', 'state.error =', 'state.transportIssue =', 'state.notice =', 'handleControlFailure', 'stalledSince')):
    raise SystemExit('Execution/manual control must not write Bluetooth diagnostics or initiate recovery.')
recovery_source = (ROOT / 'MobileHarness/App/Workflows/Bluetooth/BluetoothRecovery.swift').read_text()
if re.search(r'\b(?:import Actions|NexArmActionError|NexArmExecutionError|case resources)\b', recovery_source):
    raise SystemExit('Bluetooth recovery must not depend on Action failures/resources.')
if 'BluetoothSettingsState' in (ROOT / 'MobileHarness/UI/Conversation/ConversationView.swift').read_text():
    raise SystemExit('Home conversation must not observe Bluetooth state.')
for filename in ('App/Adapters/RuntimePresentation.swift', 'App/Lifecycle/CameraCoordinator.swift', 'UI/Camera/CameraState.swift'):
    source = (ROOT / 'MobileHarness' / filename).read_text()
    if 'trackingMessage' in source or 'trackingStatus' in source:
        raise SystemExit('Tracking execution failures belong only in home scheduling issues.')
native_source = (ROOT / 'MobileHarness/PlatformKit/Connectivity/NexArm/NexArmBluetooth.swift').read_text()
if not all(marker in native_source for marker in ('public var failure:', 'feedbackHealthy', 'isSendBlocked', 'cancelBlockedWrite')):
    raise SystemExit('SDK must own latest native status and blocked-write detection.')
if re.search(r'\b(?:ActionReport|ActionFailure|NexArmExecutionError|ToolResponse|ResourceID|AgentID)\b', native_source):
    raise SystemExit('Bluetooth SDK diagnostics must not know execution context.')
print('Bluetooth current status and execution results remain independent.')

# Keep invocation outcomes and recovery context scoped to their actual owner.
adapter_source = (ROOT / 'MobileHarness/App/Adapters/NexArmBehaviorAdapter.swift').read_text()
if 'lastActionReport' in manual_workflow or 'lastActionReport' in adapter_source:
    raise SystemExit('Motor reports must return to invocation-scoped sinks, not a shared last-result field.')
settings_source = (ROOT / 'MobileHarness/UI/Settings/BluetoothSettingsState.swift').read_text()
if re.search(r'public var (?:motionStatus|executing|testing|resetting|refreshing|controlValidated)\b', settings_source):
    raise SystemExit('Retired Bluetooth execution/verification presentation state must not return.')
controller_source = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmActionController.swift').read_text()
if 'indicateConnection' in controller_source or 'connectionIndicationUsed' in controller_source:
    raise SystemExit('Retired connection-indication motion must not return.')
protocol_source = (ROOT / 'MobileHarness/PlatformKit/Connectivity/NexArm/NexArmProtocol.swift').read_text()
if 'feedbackLost' in protocol_source:
    raise SystemExit('Action completion feedback timeout must remain outside native protocol errors.')
print('Invocation report ownership, independent native categories and retired implementation checks pass.')

# Error semantics must stay in their owning layer after admission and replacement.
if 'unsupportedFirmware' in protocol_source or 'firmwareUnavailable' in protocol_source:
    raise SystemExit('Firmware policy errors belong to Actions, not the native protocol SDK.')
if 'guard liveControlID == nil, observationID == nil else { throw CancellationError() }' in native_source:
    raise SystemExit('Channel admission must not impersonate task cancellation.')
settings_view = (ROOT / 'MobileHarness/UI/Settings/BluetoothSettingsView.swift').read_text()
for source in (manual_workflow, native_source, settings_source, settings_view):
    if any(marker in source for marker in ('BluetoothIncident', 'NexArmBluetoothDiagnostics', 'clearIncidents', 'consumeNativeIncidents', 'appendIncident', 'recordRecoveryEvent', 'incidentDevices')):
        raise SystemExit('Retired Bluetooth incident history must not return; retain current state only.')
if 'state.rowIntent(for: device.id)' not in settings_view or 'case .connect: controls.connect(device.id)' not in settings_view or 'case .openDetail: deviceForDetail = device' not in settings_view:
    raise SystemExit('Bluetooth row taps must connect disconnected devices and open only connected details.')
if 'navigationDestination(item: $deviceForDetail)' not in settings_view or 'connectionButton(' in settings_view:
    raise SystemExit('Bluetooth details require one tap-owned local destination, without duplicate connect rows.')
if any(marker in settings_source + settings_view for marker in ('detailDevice', 'pendingDetailDevice', 'resolveDeviceNavigation', 'selectDevice(', '.onAppear', '.onChange(of: state.phase)')):
    raise SystemExit('Bluetooth connection snapshots and page appearance must not mutate navigation or auto-open details.')
if 'LabeledContent("通信"' in settings_view:
    raise SystemExit('Bluetooth communication issues belong to the combined connection status and current error.')
tool_contract = (ROOT / 'MobileHarness/Tools/Runtime/Contracts/ToolResponse.swift').read_text()
if 'FailureCode' not in tool_contract or 'ToolExecutionFailureProviding' not in tool_contract:
    raise SystemExit('Tools require independent bounded producer failure codes.')
print('Latest Bluetooth status and independent Tool failure codes pass.')

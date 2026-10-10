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
for target_name, path, dependencies in (
    ('FunctionContracts', 'MobileHarness/Actions/Contracts', set()),
    ('ExecutionRuntime', 'MobileHarness/Gateway/Runtime', {'FunctionContracts'}),
    ('CallRuntime', 'MobileHarness/Gateway/Output', {'FunctionContracts', 'ExecutionRuntime'}),
):
    target = targets.get(target_name, {})
    actual = {next(iter(d.values()))[0] for d in target.get('dependencies', [])}
    if target.get('path') != path or actual != dependencies:
        errors.append(f'Invalid isolated execution target {target_name}: {actual}')
    folders = [ROOT / path] if target_name != 'CallRuntime' else [ROOT / path / 'Registration', ROOT / path / 'Protocols']
    for folder in folders:
        for source in folder.rglob('*.swift'):
            imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
            if imports - dependencies - {'Foundation', 'Synchronization'}:
                errors.append(f'Forbidden isolated execution import: {source.relative_to(ROOT)}')
if {next(iter(d.values()))[0] for d in targets['FunctionContractTests'].get('dependencies', [])} != {'FunctionContracts'}:
    errors.append('FunctionContractTests must prove contracts without execution/call dependencies')
if {next(iter(d.values()))[0] for d in targets['Gateway'].get('dependencies', [])} != {'AgentCore', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime'}:
    errors.append('Gateway must depend only on AgentCore and the three isolated execution SDKs')
if 'Contracts' not in targets['Actions'].get('exclude', []):
    errors.append('Actions must exclude its independent FunctionContracts source target')
if {next(iter(d.values()))[0] for d in targets['Actions'].get('dependencies', [])} != {'FunctionContracts', 'PlatformKit', 'BehaviorDefinitions', 'StorageChat', 'Storage'}:
    errors.append('Actions must not depend on Gateway, execution or call protocol targets')
if 'Runtime' not in targets['Gateway'].get('exclude', []) or 'Output/Registration' not in targets['Gateway'].get('exclude', []) or 'Output/Protocols' not in targets['Gateway'].get('exclude', []):
    errors.append('Gateway must exclude separately compiled execution and protocol sources')
if 'ActionRuntime' in targets or (ROOT / 'MobileHarness/Actions/Runtime').exists():
    errors.append('Retired Actions/Runtime target/source tree must not return')
for retired in ('Tools', 'ToolRuntime'):
    if retired in targets:
        errors.append(f'Retired compatibility target recreated: {retired}')
for retired in ('Tools', 'Actions/Compatibility'):
    if (ROOT / 'MobileHarness' / retired).exists():
        errors.append(f'Retired compatibility sources recreated: {retired}')
for source in (ROOT / 'MobileHarness').rglob('*.swift'):
    if re.search(r'\bimport\s+(?:Tools|ToolRuntime)\b', source.read_text()):
        errors.append(f'Retired compatibility import: {source.relative_to(ROOT)}')
for path in ('Gateway/Runtime/ActionDeadline.swift', 'Gateway/Output/Protocols/ToolExecutor.swift'):
    content = (ROOT / 'MobileHarness' / path).read_text()
    if ('CooperativeExecution.run' not in content and 'FunctionExecutor.perform' not in content) or 'withThrowingTaskGroup' in content:
        errors.append(f'Execution lifetime must use the shared ActionRuntime mechanism: {path}')
if targets['AgentCore'].get('path') != 'MobileHarness/Agents/Support/Core':
    errors.append('AgentCore must compile Agents/Support/Core')
if 'Support/Core' not in targets['Agents'].get('exclude', []):
    errors.append('Agents must exclude the separately compiled Core directory')
if not (ROOT / 'MobileHarness/Gateway/Runtime/README.md').is_file():
    errors.append('Missing consolidated execution Runtime')
# Gateway is transport-only; AgentCore remains independent of models/platform/business.
for module, forbidden in {
    'PlatformKit': {'Types', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'Agents', 'AgentCore', 'Gateway', 'UI', 'AppWorkflows', 'BehaviorAssembly'},
    'Gateway': {'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'Agents', 'PlatformKit', 'Actions', 'Tools'},
    'AgentCore': {'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'Gateway', 'Agents', 'PlatformKit', 'SwiftUI', 'UIKit', 'CoreVideo'},
}.items():
    source_root = ROOT / 'MobileHarness' / ('Agents/Support/Core' if module == 'AgentCore' else module)
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
if ui_dependencies:
    errors.append('UI must have no project dependencies')
allowed_ui = {'Foundation', 'CoreGraphics', 'Observation', 'SwiftUI', 'UIKit'}
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
    ('Actions', {'Foundation', 'Synchronization', 'PlatformKit', 'FunctionContracts'}),
    ('App/Composition/Behaviors', {'Actions', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime'}),
]:
    for source in (ROOT / 'MobileHarness' / root).rglob('*.swift'):
        if root in {'Actions', 'Tools'} and source.relative_to(ROOT / 'MobileHarness' / root).parts[0] in {'Contracts', 'Compatibility'}:
            continue  # Independent runtime imports are validated above, not as concrete domains.
        for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
            history_storage = (root == 'Actions' and source.relative_to(ROOT / 'MobileHarness/Actions').parts[0] == 'History' and imported == 'StorageChat')
            preference_storage = (root == 'Actions' and source.relative_to(ROOT / 'MobileHarness/Actions').as_posix() in {'System/Support/ModelResourcePreferencesService.swift', 'System/Support/ProviderSettingsStore.swift', 'System/Support/ProviderSettingsService.swift'} and imported == 'Storage')
            if imported not in allowed and not history_storage and not preference_storage:
                errors.append(f'Forbidden behavior-layer import {imported}: {source.relative_to(ROOT)}')
# Behavior registration belongs to domain catalogs, not individual App call sites.
behavior_target = targets.get('BehaviorAssembly', {})
if behavior_target.get('path') != 'MobileHarness/App/Composition/Behaviors':
    errors.append('BehaviorAssembly must compile the isolated composition directory')
if [next(iter(d.values()))[0] for d in behavior_target.get('dependencies', [])] != ['Actions', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime']:
    errors.append('BehaviorAssembly may depend only on behavior domains and execution runtimes')
for source in (ROOT / 'MobileHarness/App').rglob('*.swift'):
    content = source.read_text()
    if re.search(r'\b(?:ActionFunction|ToolDefinition)\s*\(|\.registerCompletion\s*\(', content):
        errors.append(f'App contains per-function behavior registration: {source.relative_to(ROOT)}')
    if 'Composition/Behaviors' not in str(source) and re.search(r'\bActionBinding\s*\(', content):
        errors.append(f'App protocol bindings must stay in behavior composition: {source.relative_to(ROOT)}')
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
# Canonical business domains own both protocols; source names do not classify by Tool versus Action.
actions_root = ROOT / 'MobileHarness/Actions'
for source in (ROOT / 'MobileHarness').rglob('*.swift'):
    content = source.read_text()
    if any(re.search(r'\b' + retired + r'\b', content) for retired in ('ToolInvocation', 'ToolExecutionContext', 'ToolHandler', 'ToolCompletionHandler')):
        errors.append(f'Retired protocol-specific implementation contract: {source.relative_to(ROOT)}')
for domain in ('UI', 'Speech', 'Camera', 'History', 'System', 'NexArm'):
    for source in (actions_root / domain).rglob('*.swift'):
        if re.search(r'\b(?:Tool\w*|ActionInvocation|ActionRequest|ActionBinding|CallProtocol|executionPolicy|directResultPolicy|protocols)\b', source.read_text()):
            errors.append(f'Business implementation consumes native wire request: {source.relative_to(ROOT)}')
macro_source = (actions_root / 'ActionMacro.swift').read_text()
if re.search(r'\b(?:protocols|executionPolicy|directResultPolicy|ActionBinding|Tool\w*)\b', macro_source):
    errors.append('@Action must describe callable functions without registration policies')
if macro_source.count('public macro Action(') != 1:
    errors.append('@Action must have one protocol-independent metadata signature')
function_contract = (actions_root / 'Contracts/ActionFunction.swift').read_text()
if re.search(r'\b(?:Tool\w*|ActionBinding|CallProtocol|protocols|executionPolicy|directResultPolicy)\b', function_contract):
    errors.append('Callable ActionFunction must remain independent of registration/runtime protocols')
macro_implementation = (ROOT / 'Macros/BehaviorDefinitions/BehaviorDefinitionMacro.swift').read_text()
if 'ToolHandler' in macro_implementation or 'ToolCompletionHandler' in macro_implementation or 'ActionBinding' in macro_implementation:
    errors.append('@Action factories must bind canonical handlers only')
if (actions_root / 'ToolMacro.swift').exists():
    errors.append('Retired @Tool macro must not be recreated')
expected_domains = {'UI', 'Speech', 'Camera', 'History', 'System', 'NexArm'}
domains = {p.name for p in actions_root.iterdir() if p.is_dir()} - {'Contracts', 'Compatibility'}
if domains != expected_domains:
    errors.append(f'Executable business domains must be classified explicitly: {domains}')
for folder, directories, files in os.walk(actions_root):
    if 'README.md' not in files:
        errors.append(f'Missing Action directory README: {Path(folder).relative_to(ROOT)}')
for name in sorted(expected_domains):
    domain = actions_root / name
    namespace_name = name + 'Actions'
    namespace = domain / (namespace_name + '.swift')
    if not namespace.exists() or not re.search(r'public enum ' + namespace_name + r'\s*\{', namespace.read_text()):
        errors.append(f'Missing canonical capability namespace: {name}')
    catalog = domain / 'Support' / (name + 'Module.swift')
    if not catalog.exists() or f'{name}Module: CapabilityModule' not in catalog.read_text():
        errors.append(f'Missing unified domain catalog: {name}')
    sources = {source: source.read_text() for source in domain.rglob('*.swift')}
    entries = {}
    for source, content in sources.items():
        if source.parent != domain:
            continue
        if not re.search(r'(?:public enum|extension) ' + namespace_name + r'\s*\{', content):
            errors.append(f'Capability entry file lacks canonical namespace: {source.relative_to(ROOT)}')
        for function in re.findall(r'public static func (\w+)\(', content):
            entries.setdefault(function, []).append(source)
        expected_module = source.stem.removesuffix('Actions')
        for declared_domain, declared_module in re.findall(r'@Action\(\s*domain: "([^"]+)", module: "([^"]+)"', content):
            if (declared_domain, declared_module) != (name, expected_module):
                errors.append(f'Invalid three-level Action metadata owner: {source.relative_to(ROOT)}')
        if '@Tool(' in content:
            errors.append(f'Capability entries must use unified @Action: {source.relative_to(ROOT)}')
    for source, content in sources.items():
        for function in re.findall(namespace_name + r'\.(\w+)Definition\(', content):
            if source.parent != domain / 'Support' or len(entries.get(function, [])) != 1:
                errors.append(f'Invalid canonical capability binding: {source.relative_to(ROOT)}: {function}')
for retired in ('ActionModules.swift', 'ToolModules.swift'):
    if (actions_root / retired).exists():
        errors.append(f'Production catalogs must use CapabilityModules instead of {retired}')
assembly = (ROOT / 'MobileHarness/App/Composition/Behaviors/BehaviorAssembly.swift').read_text()
if 'CapabilityModules.builtIn' not in assembly or 'CapabilityCatalog(modules:' not in assembly or 'bindings.actions' not in assembly or 'bindings.tools' not in assembly or 'BehaviorProtocolBindings.bind' not in assembly:
    errors.append('BehaviorAssembly must project both registries from one business-domain catalog')
# Directory/module-file/function ownership is explicit while invocation paths migrate separately.
entry_modules = {
    'UI': {'Navigation': {'open'}, 'Expression': {'express', 'setExpression'}, 'Gaze': {'moveEyes'},
           'Caption': {'print', 'setTranscript', 'finishTranscript', 'beginReplyTurn'},
           'VoiceState': {'setVoiceState'}, 'Pose': {'showPose'}, 'HistoryPresentation': {'showHistory'},
           'ResourcePresentation': {'showResources', 'showResourceFailure', 'showResourceOperationFailure', 'showResourcePreferenceFailure', 'showProviderResult'}},
    'Speech': {'Playback': {'speak'}, 'Listening': {'update'}}, 'Camera': {'Capture': {'open', 'close', 'flip', 'retry', 'takePhoto', 'savePhoto', 'ignorePhoto'}},
    'History': {'Conversation': {'list', 'read', 'delete', 'startNew', 'summarize'}}, 'System': {'Device': {'control', 'readStatus', 'readEnvironment'}, 'Provider': {'discoverModels', 'restoreSettings', 'saveSettings', 'readSettings'}, 'Runtime': {'runtimeInfo'}, 'ModelResources': {'download', 'cancel', 'remove', 'configureSpeech', 'restoreSource', 'saveSource', 'snapshotResources'}},
    'NexArm': {'Motion': {'moveMotor', 'resetMotor', 'reset', 'shakeBase'},
               'Gesture': {'nodHead', 'shakeHead', 'waveWrist', 'tiltWrist', 'lookAround', 'celebrate', 'dance'},
               'Tracking': {'aim'}},
}
for domain, modules in entry_modules.items():
    facade = actions_root / domain / (domain + 'Actions.swift')
    if re.search(r'public static func', facade.read_text()):
        errors.append(f'Domain facade must not regain callable implementations: {domain}')
    expected_files = {domain + 'Actions.swift'} | {module + 'Actions.swift' for module in modules}
    actual_files = {source.name for source in (actions_root / domain).glob('*.swift')}
    if actual_files != expected_files:
        errors.append(f'Cohesive module file ownership differs from design: {domain}: {actual_files}')
    for module, functions in modules.items():
        source = actions_root / domain / (module + 'Actions.swift')
        if not source.exists() or set(re.findall(r'public static func (\w+)\(', source.read_text())) != functions:
            errors.append(f'Invalid directory/module/function ownership: {domain}.{module}')

# Production exclusion scopes stay explicit when path modules are renamed.
for domain in ('UI', 'Speech', 'NexArm'):
    for source in (actions_root / domain).glob('*.swift'):
        for metadata in re.findall(r'@Action\((.*?)\)\s*public static func', source.read_text(), re.S):
            if any(f'module: "{module}"' in metadata for module in ('Expression', 'Playback', 'Motion', 'Gesture')) and f'serializationKey: "{domain}"' not in metadata:
                errors.append(f'Production serialization identity must remain explicit: {source.relative_to(ROOT)}')
scheduler = (ROOT / 'MobileHarness/Gateway/Output/Scheduling/ChannelScheduler.swift').read_text()
if 'busyModules' in scheduler or 'definition.serializationKey' not in scheduler or 'busySerializationKeys.contains(job.serializationKey)' not in scheduler:
    errors.append('Channel exclusion must use definition-owned keys, independently of paths')

# Compile-time generation must never acquire business/runtime dependencies.
macro = targets.get('BehaviorDefinitions')
if macro is None or macro['type'] != 'macro' or macro.get('path') != 'Macros/BehaviorDefinitions':
    errors.append('BehaviorDefinitions must remain a compile-time macro target')
elif any(next(iter(d.values()))[0] not in {'SwiftCompilerPlugin', 'SwiftSyntax', 'SwiftSyntaxBuilder', 'SwiftSyntaxMacros'} for d in macro.get('dependencies', [])):
    errors.append('BehaviorDefinitions may depend only on SwiftSyntax compiler libraries')

for module in ('Actions',):
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
    'Settings': ('AppSettingsWorkflow', {'UI', 'AgentCore', 'Agents', 'Gateway', 'AppPresentationWorkflow'}),
    'History': ('AppHistoryWorkflow', {'UI', 'StorageChat', 'AgentCore', 'Agents', 'Gateway', 'AppPresentationWorkflow', 'Actions', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime'}),
    'Bluetooth': ('AppBluetoothWorkflow', {'UI', 'AgentCore', 'Storage', 'Actions', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime', 'PlatformKit'}),
    'Speech': ('AppSpeechPlayback', {'FunctionContracts', 'StorageAudio'}),
    'Presentation': ('AppPresentationWorkflow', {'UI', 'AgentCore', 'FunctionContracts'}),
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
# Resource transport is the only Settings source allowed to depend on Agent routing.
for source in (ROOT / 'MobileHarness/App/Workflows/Settings').glob('*.swift'):
    allowed = ({'AgentCore', 'Agents', 'Gateway', 'AppPresentationWorkflow'} if source.name in {'ApplicationControlIntentRuntime.swift', 'PhotographerIntentRuntime.swift', 'AgentInteractionRuntime.swift'} else {'UI', 'Agents'} if source.name in {'CameraInteractionWorkflow.swift', 'BluetoothInteractionWorkflow.swift'} else {'UI'})
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - allowed - {'Foundation', 'Security'}:
        errors.append(f'Unexpected resource role import: {source.relative_to(ROOT)}')
resource_assembly = (ROOT / 'MobileHarness/App/Composition/AppAssembly.swift').read_text()
if re.search(r'\.(?:downloadArtifact|cancelArtifact|removeArtifact)\(', resource_assembly):
    errors.append('Settings resource mutations must cross Agent/Gateway commands')
# Preference application must enter Agent routing; native lifecycle binding stays injected.
if 'applicationControlIntents.preferences(intent)' not in resource_assembly:
    errors.append('Preference restore/save must cross ApplicationControl')
preferences_facade = (ROOT / 'MobileHarness/App/Workflows/Settings/ModelResourcesWorkflow.swift').read_text()
provider_facade = (ROOT / 'MobileHarness/App/Workflows/Settings/SettingsWorkflow.swift').read_text()
if (ROOT / 'MobileHarness/App/Workflows/Settings/CloudSettingsStore.swift').exists():
    errors.append('Provider settings persistence belongs to Actions, not App workflows')
if re.search(r'provider\.prepare|store\.(?:load|save)\(|LocalDocumentStore', provider_facade):
    errors.append('Provider settings facade cannot own preparation or persistence transactions')
if re.search(r'LocalDocumentStore|\.(?:save|load)\(|\bnormalized\b', preferences_facade):
    errors.append('Settings preference facade cannot own persistence/normalization')
if 'intents.inventory()' not in resource_assembly or 'intents.presentInventory(generation: generation)' not in resource_assembly:
    errors.append('Resource refresh must cross ApplicationControl')
for source in (ROOT / 'MobileHarness/App/Workflows/Settings').glob('*.swift'):
    if 'ModelResourcePolicy' in source.read_text():
        errors.append('Installed resource eligibility belongs to Actions inventory')
resource_interaction = (ROOT / 'MobileHarness/App/Workflows/Settings/ModelResourceInteractionWorkflow.swift').read_text()
if re.search(r'state\.(?:items|installedGroups)\s*=', resource_interaction):
    errors.append('Resource refresh state commits must use registered presentation')
resource_agent = '\n'.join(source.read_text() for source in (ROOT / 'MobileHarness/Agents/ApplicationControl').glob('*.swift'))
if 'Camera.Capture.' in resource_agent:
    errors.append('Camera decisions/grants belong to Photographer, not ApplicationControl')
if set(re.findall(r'\bimport\s+(\w+)', resource_agent)) - {'AgentCore', 'Foundation', 'ModelKit', 'StorageChat'}:
    errors.append('ApplicationControl actor must remain independent of implementations')
# History transport is a narrow staged exception, not blanket feature policy access.
history_source_boundaries = {
    'ConversationHistoryWorkflow.swift': {'UI', 'StorageChat'},
    'HistoryIntentRuntime.swift': {'AgentCore', 'Agents', 'Gateway', 'AppPresentationWorkflow'},
    'HistoryPresentationAdapter.swift': {'UI', 'StorageChat', 'Actions', 'FunctionContracts', 'AgentCore', 'Agents'},
}
for name, allowed in history_source_boundaries.items():
    source = ROOT / 'MobileHarness/App/Workflows/History' / name
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - allowed - {'Foundation'}:
        errors.append(f'Unexpected history role import: {source.relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness/Agents/Memory').glob('*.swift'):
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    allowed = {'Foundation', 'ModelKit', 'StorageChat'} if source.name == 'ConversationTitleGenerator.swift' else {'Foundation', 'AgentCore', 'ModelKit', 'StorageChat'}
    if imports - allowed:
        errors.append(f'Unexpected memory computation/coordination imports: {source.relative_to(ROOT)}')
    if source.name == 'ConversationTitleGenerator.swift' and re.search(r'\.(?:setTitle|startNew|deleteArchived)\(|\b(?:Gateway|ActionCall|ToolCall)\b', source.read_text()):
        errors.append('Title computation cannot execute mutations or calls')
# Typed history content belongs to business Agents; framework input stays domain-neutral.
history_agent = (ROOT / 'MobileHarness/Agents/Memory/MemoryAgent.swift').read_text()
core_input = (ROOT / 'MobileHarness/Agents/Support/Core/AgentInput.swift').read_text()
if 'MemoryHistoryIntent(rawValue:' in history_agent or 'MemoryHistoryIntent' in core_input:
    errors.append('History intent must use typed domain content outside Core payloads')
result_ledger = (ROOT / 'MobileHarness/Gateway/Output/Results/ActionResultLedger.swift').read_text()
if 'SignalCausality(envelope: invocation.envelope)' not in result_ledger:
    errors.append('Scheduled feedback must retain original envelope causality')
# Resource UI state must remain passive; asynchronous effects belong to the feature.
resource_state = (ROOT / 'MobileHarness/UI/Settings/ModelResourcesState.swift').read_text()
resource_implementation = resource_state.split('public final class ModelResourcesState', 1)[1]
if re.search(r'\bTask\b|\basync\b|\bModelResourcesOperating\b', resource_implementation):
    errors.append('ModelResourcesState owns resource operation effects')
if 'ModelResourceSelectionError' in resource_state or 'func isInstalled(in:' in resource_state:
    errors.append('Resource installation policy belongs to AppSettingsWorkflow')
if (ROOT / 'Tests/UITests/ModelResourcesStateTests.swift').exists():
    errors.append('Resource operation tests belong to AppWorkflowTests')
# History deletion must be selected by Agents/Tools, never the legacy host workflow.
legacy_history = (ROOT / 'MobileHarness/App/Workflows/History/ConversationHistoryWorkflow.swift').read_text()
if 'store.deleteArchived(' in legacy_history:
    errors.append('History mutation/inference bypasses the Agent capability path')
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
if 'preempts: [.assistant: [.photographer], .applicationControl: [.photographer]]' not in runtime or 'allowedOwners: [.assistant, .applicationControl, .photographer]' not in runtime or 'executionGroup:' not in runtime:
    errors.append('Composition must grant Assistant/fixed ApplicationControl writers joined takeover of Photographer')
if 'trackingInputAvailable' not in runtime or '[weak photographerAgent]' not in runtime or 'hasFreshPose()' not in runtime:
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
tool_dependencies = {next(iter(d.values()))[0] for d in targets['Actions'].get('dependencies', [])}
if 'StorageChat' not in tool_dependencies:
    errors.append('History Tools require the explicit StorageChat dependency')
for source in (ROOT / 'MobileHarness/Actions/History').rglob('*.swift'):
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - {'Foundation', 'FunctionContracts', 'StorageChat'}:
        errors.append(f'History Tools have non-foundational imports: {source.relative_to(ROOT)}')
# Feature-specific presentation contracts must not return to Agent infrastructure.
if (ROOT / "MobileHarness/Agents/Support/Core/Output/PoseOverlay.swift").exists():
    errors.append("PoseOverlay belongs to UI/Camera, not AgentCore")

# Physical consolidation preserves distinct framework/contracts/capability/persistence layers.
for layer, allowed in {
    'Core': {'Foundation'},
    'Communication': {'Foundation', 'AgentCore'},
    'Context': {'Foundation', 'AgentCore', 'Storage'},
    'Chat': {'Foundation', 'AgentCore', 'ModelKit', 'StorageChat'},
}.items():
    for source in (ROOT / 'MobileHarness/Agents/Support' / layer).rglob('*.swift'):
        imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
        if imports - allowed:
            errors.append(f'Forbidden Support/{layer} imports {sorted(imports - allowed)}: {source.relative_to(ROOT)}')

# Core owns generic contracts, never built-in application Agents or speech policy.
core_dependencies = [next(iter(d.values()))[0] for d in targets['AgentCore'].get('dependencies', [])]
if core_dependencies != []:
    errors.append('AgentCore must have zero project dependencies')
core_identity = (ROOT / 'MobileHarness/Agents/Support/Core/AgentID.swift').read_text()
if 'public static let' in core_identity:
    errors.append('Concrete application Agent identities belong to Agents')
core_prompt = (ROOT / 'MobileHarness/Agents/Support/Core/Capability/CapabilityContextBuilder.swift').read_text()
if any(marker in core_prompt for marker in ('speechChannel', 'audio playback', 'Speak-then-act')):
    errors.append('Assistant speech policy must not enter AgentCore prompt construction')
for source in (ROOT / 'MobileHarness/Agents/Support/Core').rglob('*.swift'):
    if re.search(r'public (?:struct|enum) (?:PoseObservation|SpeechPhase|SpeechSynthesisInput)\b', source.read_text()):
        errors.append('Agent communication domain values belong to Agents/Support/Communication')

# Generic communication infrastructure must not regain application domain schemas or camera samples.
for directory in ('MobileHarness/Agents/Support/Core', 'MobileHarness/Gateway'):
    for source in (ROOT / directory).rglob('*.swift'):
        content = source.read_text()
        if any(marker in content for marker in ('"speech.', '"vision.', '"sound.', '"phone.', 'gray64', 'PerceptionMessage')):
            errors.append(f'Domain communication policy in generic infrastructure: {source.relative_to(ROOT)}')
if (ROOT / 'MobileHarness/Agents/Support/Core/Communication/PerceptionInput.swift').exists() or (ROOT / 'MobileHarness/Agents/Support/Core/ImageInput.swift').exists():
    errors.append('Domain/media input definitions must not return to Core')
if 'public enum AgentMessage' in (ROOT / 'MobileHarness/Agents/Support/Core/Communication/AgentMessaging.swift').read_text():
    errors.append('Core AgentMessage must remain generic, not a closed business enum')

# Core resources/results and lexical parsing must remain business-neutral.
for source in [*(ROOT / 'MobileHarness/Agents/Support/Core').rglob('*.swift'), *(ROOT / 'MobileHarness/Gateway').rglob('*.swift')]:
    content = source.read_text()
    if any(marker in content for marker in ('"camera.capture"', 'cameraCapture', 'public let motor: Int', 'public let target: Int', 'public let observed: Int', 'case targetNotReached', 'case invalidPose', 'controlNotReady', 'feedbackTimeout')):
        errors.append(f'Concrete resource/result policy in generic infrastructure: {source.relative_to(ROOT)}')
sentence_source = (ROOT / 'MobileHarness/Agents/Support/Core/Generation/SentenceFunctionBuffer.swift').read_text()
if re.search(r'containsHanzi\s*\?\s*60\s*:\s*120', sentence_source):
    errors.append('Assistant soft text limits must not be fixed in Core')

# Speech helpers own perception only, independently of Agent transport/presentation.
speech_root = ROOT / 'MobileHarness/Agents/SpeechPerception'
for name, filename in (
    ('VoiceActivitySegmenter', 'VoiceActivitySegmenter.swift'),
    ('SpeechBoundaryPolicy', 'SpeechBoundaryPolicy.swift'),
    ('SpeechRecognitionTurn', 'SpeechRecognitionTurn.swift'),
    ('TranscriptAccumulator', 'SpeechRecognitionTurn.swift'),
):
    source = speech_root / filename
    if not source.is_file():
        errors.append(f'Missing speech helper: {name}')
        continue
    content = source.read_text()
    if not re.search(rf'\b(?:struct|actor|class|enum)\s+{name}\b', content):
        errors.append(f'Missing speech helper declaration: {name}')
    imports = re.findall(r'^import (\w+)', content, re.MULTILINE)
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

# A domain owns one executable catalog; protocol adapters share definition/result types.
for source in (ROOT / 'MobileHarness').rglob('*.swift'):
    if re.search(r'\b(?:ToolDefinition|ToolResource)\b', source.read_text()):
        errors.append(f'Retired protocol naming alias: {source.relative_to(ROOT)}')
input_contract = (actions_root / 'Contracts/FunctionInput.swift').read_text()
request_contract = (actions_root / 'Contracts/FunctionRequest.swift').read_text()
if 'public protocol FunctionInput: Sendable' not in input_contract or re.search(r'\b(?:channel|protocols|ActionRequest|ToolRequest)\b', request_contract):
    errors.append('Function contracts must expose standard input without call protocol or Channel')
for source in actions_root.glob('*/Support/*Module.swift'):
    if ': CapabilityModule' in source.read_text() and 'public var definitions:' not in source.read_text():
        errors.append(f'Domain lacks canonical executable catalog: {source.relative_to(ROOT)}')

for registry in ('ActionRegistry.swift', 'ToolRegistry.swift'):
    if 'definition.validate()' not in (ROOT / 'MobileHarness/Gateway/Output/Registration' / registry).read_text():
        errors.append(f'Registry must use shared executable metadata validation: {registry}')
for source in (ROOT / 'MobileHarness/Agents').rglob('*.agent.json'):
    configuration = json.loads(source.read_text())
    agents_root = ROOT / 'MobileHarness/Agents'
    if source.parent != agents_root:
        role = source.parent.name
        actor = source.parent / f'{role}Agent.swift'
        if source.name != f'{role}.agent.json' or configuration.get('id') != role[:1].lower() + role[1:]:
            errors.append(f'Agent directory/configuration/identity naming mismatch: {source.relative_to(ROOT)}')
        if not actor.is_file() or not (re.search(rf'public actor {re.escape(role)}Agent\s*:\s*Agent\b', actor.read_text()) or (role == 'Assistant' and 'public typealias AssistantAgent = AgentChatWorker<AssistantContextState>' in actor.read_text())):
            errors.append(f'Agent role lacks its canonical actor: {source.relative_to(ROOT)}')
    else:
        errors.append(f'Concrete Agent configuration belongs in its role directory: {source.relative_to(ROOT)}')
    if configuration.get('version') != 6:
        errors.append(f'Agent configuration must use explicit v6 bindings: {source.relative_to(ROOT)}')
    for actions in configuration.get('actions', {}).values():
        for action in actions:
            if set(action.get('path', {})) != {'domain', 'module', 'function'}:
                errors.append(f'Action address lacks three fields: {source.relative_to(ROOT)}')
    for tool in configuration.get('tools', []):
        if set(tool) != {'path', 'definition'} or set(tool.get('path', {})) != {'domain', 'module', 'function'}:
            errors.append(f'Native Tool binding lacks explicit address/definition: {source.relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness').rglob('*'):
    if source.is_file() and source.suffix in {'.swift', '.json'} and re.search(r'\b(?:ConversationMemoryAgent|conversationMemory|ConversationMemoryIntent|ResourceManagementAgent|resourceManagement|ResourceIntentRuntime|ResourceIntentFailure)\b', source.read_text()):
        errors.append(f'Retired Memory role alias: {source.relative_to(ROOT)}')
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
for source in (ROOT / 'MobileHarness/Agents/Support/Core/Input').rglob('*.swift'):
    declared = set(re.findall(r'\b(?:struct|enum|protocol|typealias)\s+(\w+)', source.read_text()))
    if declared & domain_names:
        raise SystemExit(f'Agent-domain value in generic input contracts: {source.relative_to(ROOT)}')
for name, filename in [('SpeechPhase', 'SpeechValues.swift'), ('SpeechSynthesisInput', 'SpeechValues.swift'), ('PoseObservation', 'PoseObservation.swift')]:
    source = ROOT / 'MobileHarness/Agents/Support/Communication' / filename
    if not source.is_file() or not re.search(r'public (?:struct|enum) ' + name + r'\b', source.read_text()):
        raise SystemExit(f'Missing Agent-owned domain value: {name}')
if re.search(r'\b(?:outOfOrder|wrongSession)\b', (ROOT / 'MobileHarness/Agents/Support/Core/Input/ImageInput.swift').read_text()):
    raise SystemExit('Image transport values must not own receiver ordering/session policy')
print('Agent-domain values and transport/presentation ownership passed.')

if not (ROOT / "MobileHarness/UI/Camera/PoseOverlay.swift").is_file():
    raise SystemExit("Missing UI-owned PoseOverlay")

for filename, names in [('AudioInput.swift', {'AudioInput', 'AudioValidationError'}), ('ImageInput.swift', {'ImageInput', 'ImageAttachment', 'ImageInputError'})]:
    source = ROOT / 'MobileHarness/Agents/Support/Core/Input' / filename
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
for directory in ('Gateway/Runtime', 'Gateway/Output/Registration', 'Gateway/Output/Protocols'):
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
tool_contract = (ROOT / 'MobileHarness/Gateway/Output/Protocols/ToolResponse.swift').read_text()
if 'typealias FailureCode = ActionExecutionFailureCode' not in tool_contract or 'ActionExecutionFailureProviding' not in (actions_root / 'Contracts/ActionExecutionFailure.swift').read_text():
    raise SystemExit('Tools require independent bounded producer failure codes.')
print('Latest Bluetooth status and independent Tool failure codes pass.')

# Returning Tool feedback must not use the public external Signal entry point.
tool_dispatch_source = (ROOT / 'MobileHarness/Gateway/Output/Dispatch/ToolDispatcher.swift').read_text()
if 'input.send(' in tool_dispatch_source or 'input.deliverToolResult(' not in tool_dispatch_source:
    raise SystemExit('Returning Tool feedback must use captured-owner runtime admission.')
output_envelope_source = (ROOT / 'MobileHarness/Agents/Support/Core/Output/OutputEnvelope.swift').read_text()
if 'self.inputMetadata = input.metadata' not in output_envelope_source:
    raise SystemExit('Output envelopes must retain original Signal context for feedback.')

# Resource progress belongs to root input adaptation, never a page-owned polling loop.
resource_view = (ROOT / 'MobileHarness/UI/Settings/ModelResourcesView.swift').read_text()
if 'controls.refresh()' in resource_view or 'Task.sleep(for: .seconds(1))' in resource_view:
    raise SystemExit('Resource page cannot own status polling.')
observer_source = (ROOT / 'MobileHarness/App/Workflows/Settings/ResourceObservationWorkflow.swift').read_text()
if set(re.findall(r'\bimport\s+(\w+)', observer_source)) - {'Foundation'}:
    raise SystemExit('Resource observation must remain an injected input adapter.')

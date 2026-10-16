#!/usr/bin/env python3
"""Validate the project's ModelKit source and target dependency boundary."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'MobileHarness/ModelKit'
FORBIDDEN = {'StorageTasks', 'StorageMedia', 'StorageDevices', 'StorageSQLite', 'AgentCore', 'Agents', 'Gateway', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'PlatformKit', 'SwiftUI', 'UIKit', 'HarnessKit', 'UI', 'AppWorkflows', 'BehaviorAssembly', 'Types'}
SYSTEM_MODULES = {
    'Foundation', 'Synchronization', 'CoreFoundation', 'Darwin', 'os',
    'AVFAudio', 'Speech', 'CoreVideo', 'CoreML', 'CoreAI', 'Metal',
    'Accelerate', 'Vision', 'ImageIO', 'Compression', 'CryptoKit',
}
THIRD_PARTY_PRODUCTS = {
    'ModelKitGemma4': {'CoreAILM': 'coreai-models', 'Tokenizers': 'swift-transformers'},
    'ModelKitNemotron': {'FluidAudio': 'fluidaudio'},
    'ModelKitKokoro': {'FluidAudio': 'fluidaudio'},
    'ModelKitHub': {'HuggingFace': 'swift-huggingface'},
}
THIRD_PARTY_IMPORTS = {
    'ModelKitGemma4': {'CoreAILanguageModels', 'Tokenizers'},
    'ModelKitNemotron': {'FluidAudio'}, 'ModelKitKokoro': {'FluidAudio'},
    'ModelKitHub': {'HuggingFace'},
}


def imported_modules(content):
    return set(re.findall(r'^\s*(?:@\w+\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)', content, re.M))


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
# Manifest inspection needs no dependency resolution or the application's active build cache.
with tempfile.TemporaryDirectory(prefix='modelkit-boundary-') as scratch:
    package = json.loads(subprocess.check_output(
        ['swift', 'package', '--scratch-path', scratch, 'dump-package'], cwd=ROOT))
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
        if kind == 'product':
            expected_package = THIRD_PARTY_PRODUCTS.get(target['name'], {}).get(name)
            actual_package = values[1].lower() if values[1] else None
            if expected_package is None or actual_package != expected_package:
                errors.append(f"Third-party dependency outside its owner/package: {target['name']} -> {name} ({actual_package})")
        elif kind not in {'byName', 'target'}:
            errors.append(f"Unsupported ModelKit dependency kind: {target['name']} -> {kind}")
        if name in FORBIDDEN:
            errors.append(f"Forbidden target dependency: {target['name']} -> {name}")
    if target['name'] == 'ModelKitRuntime':
        names = [next(iter(d.values()))[0] for d in dependencies]
        if names != ['ModelKit']:
            errors.append('ModelKitRuntime must depend only on ModelKit')
hub_target = next(t for t in package['targets'] if t['name'] == 'ModelKitHub')
if {next(iter(d.values()))[0] for d in hub_target['dependencies']} != {'ModelKitRuntime', 'HuggingFace'}:
    errors.append('ModelKitHub must depend only on Management contracts and the concrete Hub SDK')
# Shared directory grouping must not erase compilation or domain ownership.
model_targets = {t['name']: t for t in package['targets'] if t['name'].startswith('ModelKit') and t['type'] == 'regular'}
all_targets = {t['name']: t for t in package['targets']}

external_project_targets = set(all_targets) - set(model_targets)
remote_packages = {
    dependency['sourceControl'][0]['identity'].lower()
    for dependency in package['dependencies'] if 'sourceControl' in dependency
}
for name, target in model_targets.items():
    if not (ROOT / target['path']).resolve().is_relative_to(KIT.resolve()):
        errors.append(f'ModelKit target sources outside SDK: {name}')
    for dependency in target.get('dependencies', []):
        kind, values = next(iter(dependency.items()))
        if kind == 'product' and (not values[1] or values[1].lower() not in remote_packages):
            errors.append(f'ModelKit product must come from a declared remote package: {name} -> {values[0]}')

# Check every production target and SDK product, even if a future intermediate target
# has a ModelKit-looking name. Host product bundling creates no reverse SDK dependency.
def audit_sdk_closure(root_name, roots):
    pending = list(roots)
    visited = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        if name not in model_targets:
            errors.append(f'SDK dependency reaches non-ModelKit target: {root_name} -> {name}')
            continue
        for dependency in model_targets[name].get('dependencies', []):
            kind, values = next(iter(dependency.items()))
            if kind in {'byName', 'target'}:
                pending.append(values[0])


for name in model_targets:
    audit_sdk_closure(name, [name])
for product in package['products']:
    if product['name'].startswith('ModelKit'):
        audit_sdk_closure(product['name'], product['targets'])
# Every implementation target has an explicit layer; providers must never import each other.
expected_model_dependencies = {
    'ModelKit': set(), 'ModelKitRuntime': {'ModelKit'},
    'ModelKitDefaults': {'ModelKit', 'ModelKitRuntime', 'ModelKitNemotron', 'ModelKitSilero',
        'ModelKitMossNano', 'ModelKitGemma4', 'ModelKitYOLOPose', 'ModelKitOpenAI', 'ModelKitAppleSpeech', 'ModelKitEnergy'},
    'ModelKitHub': {'ModelKitRuntime'},
    'ModelKitCoreAI': set(), 'ModelKitCoreML': set(),
    'ModelKitAppleSpeech': {'ModelKit'}, 'ModelKitEnergy': {'ModelKit'},
    'ModelKitNemotron': {'ModelKit'}, 'ModelKitKokoro': {'ModelKit'}, 'ModelKitMossNano': {'ModelKit'},
    'ModelKitGemma4': {'ModelKit'}, 'ModelKitOpenAI': {'ModelKit'},
    'ModelKitSilero': {'ModelKit', 'ModelKitCoreML'}, 'ModelKitYOLOPose': {'ModelKit', 'ModelKitCoreML'},
}
if set(model_targets) != set(expected_model_dependencies):
    errors.append('Every ModelKit target requires an explicit foundation/shared/assembly/provider classification')
for name, target in model_targets.items():
    project_dependencies = {
        next(iter(d.values()))[0] for d in target.get('dependencies', [])
        if next(iter(d)) in {'byName', 'target'}
    }
    if project_dependencies != expected_model_dependencies.get(name):
        errors.append(f'ModelKit layer dependency mismatch: {name} -> {project_dependencies}')
owners = {}
for name, target in model_targets.items():
    base = ROOT / target['path']
    excluded = [base / path for path in target.get('exclude', [])]
    sources = target.get('sources') or ['.']
    for relative in sources:
        path = base / relative
        candidates = [path] if path.is_file() else path.rglob('*.swift')
        for source in candidates:
            if source.suffix != '.swift' or any(source == path or path in source.parents for path in excluded):
                continue
            if not source.resolve().is_relative_to(KIT.resolve()):
                errors.append(f'ModelKit source outside SDK: {source}')
            previous = owners.setdefault(source, name)
            if previous != name:
                errors.append(f'Duplicate ModelKit source ownership: {source.relative_to(ROOT)} ({previous}, {name})')
for source in KIT.rglob('*.swift'):
    if source not in owners:
        errors.append(f'Unowned ModelKit source: {source.relative_to(ROOT)}')
management = 'MobileHarness/ModelKit/Support/Management'
for name in ('ModelKitRuntime', 'ModelKitDefaults'):
    if model_targets[name]['path'] != management or not model_targets[name].get('sources'):
        errors.append(f'{name} requires an explicit source list in the unified Management directory')
for source, name in owners.items():
    imports = imported_modules(source.read_text())
    permitted = expected_model_dependencies.get(name, set()) | {name}
    for module in imports & external_project_targets:
        errors.append(f'External project import {module}: {source.relative_to(ROOT)}')
    for module in imports - permitted - SYSTEM_MODULES - THIRD_PARTY_IMPORTS.get(name, set()):
        errors.append(f'Unapproved SDK import {module}: {source.relative_to(ROOT)}')
    if {i for i in imports if i.startswith('ModelKit')} - permitted:
        errors.append(f'ModelKit source imports outside its layer: {source.relative_to(ROOT)}')
    if name == 'ModelKitRuntime' and any(i.startswith('ModelKit') and i != 'ModelKit' for i in imports):
        errors.append(f'Concrete/default dependency in Runtime: {source.relative_to(ROOT)}')
    if KIT / 'Support/Core' in source.parents and imports - {'Foundation', 'Synchronization', 'CoreVideo'}:
        errors.append(f'Non-neutral Core dependency: {source.relative_to(ROOT)}')
for source in (KIT / 'Support/Core').glob('*.swift'):
    content = source.read_text()
    if re.search(r'\b(?:conversationID|ModelState|ProvidedCapability|ModelManager|ModelID)\b', content):
        errors.append(f'Business/management identity in Core: {source.relative_to(ROOT)}')
    if re.search(r'guard (?:active|waiters) < \d+', content):
        errors.append(f'Hardcoded runtime loading policy in Core: {source.relative_to(ROOT)}')
# Typecheck Core alone: same-target capability declarations must not hide a reverse dependency.
core_sources = sorted(str(source) for source in (KIT / 'Support/Core').glob('*.swift'))
try:
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-typecheck',
        '-module-name', 'ModelKitCoreBoundary', *core_sources], cwd=ROOT, check=True)
except subprocess.CalledProcessError:
    errors.append('Core must typecheck without domain contracts, Management or provider sources')

for source in (KIT / 'Support/Backends').rglob('*.swift'):
    if re.search(r'\b(?:Gemma|GemmaResponseText|LocalNemotronEngine|LocalKokoroEngine|LocalMossEngine|PoseTensorReader|YOLOImageGraph)\b|gemma4_|YOLO26|\[1, 300, 57\]', source.read_text()):
        errors.append(f'Model-specific implementation in generic backend: {source.relative_to(ROOT)}')
for name in ('ModelKitFluidAudio', 'ModelKitMossCoreML'):
    if name in model_targets:
        errors.append(f'Retired mixed-model target: {name}')
for relative in ('Core', 'Backends', 'Management', 'Defaults', 'Speech/Shared'):
    if (KIT / relative).exists():
        errors.append(f'Retired ModelKit directory: {relative}')
for source in KIT.rglob('*.swift'):
    if re.search(r'\b(?:GenerationControl|MossCancellation|KokoroCancellation)\b', source.read_text()):
        errors.append(f'Duplicate worker cancellation implementation: {source.relative_to(ROOT)}')

# Consolidated source ownership must retain an acyclic, non-overlapping build map.
targets = {t['name']: t for t in package['targets']}

def target_sources(target):
    root = ROOT / target['path']
    excluded = [root / name for name in target.get('exclude', [])]
    candidates = []
    for item in target.get('sources') or ['.']:
        path = root / item
        candidates.extend([path] if path.is_file() else path.rglob('*.swift'))
    return {path.resolve() for path in candidates if path.suffix == '.swift'
            and not any(path.resolve() == x.resolve() or x.resolve() in path.resolve().parents for x in excluded)}


binding_sources = {name: target_sources(targets[name]) for name in ('AgentBindings', 'ActionBindings')}
integration_sources = set().union(*binding_sources.values())

for target_name, path, dependencies in (
    ('FunctionContracts', 'MobileHarness/Actions/Support/Contracts', set()),
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
if 'Support/Contracts' not in targets['Actions'].get('exclude', []):
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
if 'Agents/Support/Core' not in targets['Agents'].get('exclude', []):
    errors.append('Agents must exclude the separately compiled Core directory')
if not (ROOT / 'MobileHarness/Gateway/Runtime/README.md').is_file():
    errors.append('Missing consolidated execution Runtime')
# Gateway is transport-only; AgentCore remains independent of models/platform/business.
for module, forbidden in {
    'PlatformKit': {'StorageTasks', 'StorageMedia', 'StorageDevices', 'StorageSQLite', 'Types', 'Storage', 'StorageChat', 'StorageAudio', 'Actions', 'Tools', 'Agents', 'AgentCore', 'Gateway', 'UI', 'AppWorkflows', 'BehaviorAssembly'},
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
agent_allowed = {'FunctionContracts', 'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio', 'StorageTasks', 'PlatformKit', 'Foundation'}
for source in (ROOT / 'MobileHarness/Agents').rglob('*.swift'):
    if source.resolve() in integration_sources or 'Core' in source.relative_to(ROOT / 'MobileHarness/Agents').parts:
        continue
    for imported in re.findall(r'\bimport\s+(\w+)', source.read_text()):
        if imported not in agent_allowed:
            errors.append(f'Forbidden Agents import {imported}: {source.relative_to(ROOT)}')
agent_target = next(t for t in package['targets'] if t['name'] == 'Agents')
for dependency in agent_target.get('dependencies', []):
    name = next(iter(dependency.values()))[0]
    if name not in {'FunctionContracts', 'AgentCore', 'ModelKit', 'Storage', 'StorageChat', 'StorageAudio', 'StorageTasks', 'PlatformKit'}:
        errors.append(f'Forbidden Agents dependency: {name}')
# Common storage contracts/implementations are independent of record domains and GRDB.
storage_target = targets['Storage']
if storage_target.get('dependencies') or storage_target.get('path') != 'MobileHarness/Storage/Support':
    errors.append('Storage must compile backend-independent Support with no target dependencies')
if 'Persistence/SQLite' not in storage_target.get('exclude', []):
    errors.append('Storage common core must exclude the SQLite backend')
record_domains = {'Chat', 'Audio', 'Media', 'Tasks', 'Devices'}
for domain in record_domains:
    name = 'Storage' + domain
    target = targets.get(name, {})
    expected = ['Storage', 'StorageTasks'] if domain == 'Chat' else ['Storage']
    actual = [next(iter(d.values()))[0] for d in target.get('dependencies', [])]
    if target.get('path') != 'MobileHarness/Storage/' + domain or actual != expected:
        errors.append(f'Unexpected {name} compilation/dependencies: {actual}')
    for source in (ROOT / 'MobileHarness/Storage' / domain).glob('*.swift'):
        imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
        if source.name.startswith('SQLite'):
            if source.name not in target.get('exclude', []):
                errors.append(f'Domain contract target includes backend: {source.relative_to(ROOT)}')
            allowed = {'Foundation', 'Storage', name, 'GRDB', 'CryptoKit'}
        else:
            allowed = {'Foundation', 'Storage', 'Synchronization'} | ({'StorageTasks'} if domain == 'Chat' else set())
        if imports - allowed:
            errors.append(f'Unexpected storage domain imports {imports - allowed}: {source.relative_to(ROOT)}')
common_root = ROOT / 'MobileHarness/Storage/Support'
for source in common_root.rglob('*.swift'):
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if 'SQLite' in source.relative_to(common_root).parts:
        allowed = {'Foundation', 'Synchronization', 'GRDB', 'Storage'}
        if re.search(r'CREATE TABLE|dialog_id|media_files|task_messages|devices\(', source.read_text()):
            errors.append(f'Generic SQLite support contains domain schema: {source.relative_to(ROOT)}')
    else:
        allowed = {'Foundation', 'Synchronization', 'CryptoKit'}
    if imports - allowed:
        errors.append(f'Unexpected common storage imports {imports - allowed}: {source.relative_to(ROOT)}')
backend = targets.get('StorageSQLite', {})
backend_dependencies = {next(iter(d.values()))[0] for d in backend.get('dependencies', [])}
if backend_dependencies != {'Storage', 'StorageChat', 'StorageTasks', 'StorageMedia', 'StorageDevices', 'GRDB'}:
    errors.append('StorageSQLite alone must own the GRDB dependency and domain adapters')
for target in package['targets']:
    dependencies = {next(iter(d.values()))[0] for d in target.get('dependencies', [])}
    if target.get('name') not in {'StorageSQLite', 'IntegrationTests'} and 'GRDB' in dependencies:
        errors.append(f'GRDB leaked into {target.get("name")}')
    if target.get('name') != 'IntegrationTests' and 'StorageSQLite' in dependencies:
        errors.append(f'Backend dependency outside application construction: {target.get("name")}')
for parent in ['Agents', 'Actions']:
    for source in (ROOT / 'MobileHarness' / parent).rglob('*.swift'):
        if re.search(r'\bimport\s+(?:GRDB|StorageSQLite)\b|\b(?:RecordDatabase|SQLiteRepositories|SQLiteChatRepository|SQLiteTaskRepository|SQLiteMediaRepository|SQLiteDeviceRepository)\b', source.read_text()):
            errors.append(f'Concrete record backend leaked to consumer: {source.relative_to(ROOT)}')
for path, directories, files in os.walk(ROOT / 'MobileHarness/Storage'):
    if 'README.md' not in files:
        errors.append(f'Missing Storage directory README: {Path(path).relative_to(ROOT)}')
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
coordinator = (ROOT / 'MobileHarness/Agents/Support/VoiceSessionCoordinator.swift').read_text()
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
# Public rendering frameworks are confined to the native companion implementation.
native_ui_imports = {
    'Components/NativeCompanionSurface.swift': {'QuartzCore'},
    'Components/MetalHaloRenderer.swift': {'Metal', 'QuartzCore', 'Synchronization'},
}
for source in (ROOT / 'MobileHarness/UI').rglob('*.swift'):
    content = source.read_text()
    for imported in re.findall(r'\bimport\s+(\w+)', content):
        if imported not in allowed_ui | native_ui_imports.get(str(source.relative_to(ROOT / 'MobileHarness/UI')), set()):
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
for source in target_sources(targets['Actions']):
    if 'Support/Contracts' in str(source):
        continue
    allowed = {'Foundation', 'Synchronization', 'PlatformKit', 'FunctionContracts', 'Storage'}
    if source.is_relative_to(ROOT / 'MobileHarness/Actions/History'):
        allowed.add('StorageChat')
    for imported in imported_modules(source.read_text()):
        if imported not in allowed:
            errors.append(f'Forbidden core Actions import {imported}: {source.relative_to(ROOT)}')
# Integration owns registration; executable App only installs complete module declarations.
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
        if source.resolve() in integration_sources:
            continue
        if re.search(r'\b(?:Tool\w*|ActionInvocation|ActionRequest|ActionBinding|CallProtocol|executionPolicy|directResultPolicy|protocols)\b', source.read_text()):
            errors.append(f'Business implementation consumes native wire request: {source.relative_to(ROOT)}')
macro_source = (actions_root / 'Support/ActionMacro.swift').read_text()
if re.search(r'\b(?:protocols|executionPolicy|directResultPolicy|ActionBinding|Tool\w*)\b', macro_source):
    errors.append('@Action must describe callable functions without registration policies')
if macro_source.count('public macro Action(') != 1:
    errors.append('@Action must have one protocol-independent metadata signature')
function_contract = (actions_root / 'Support/Contracts/ActionFunction.swift').read_text()
if re.search(r'\b(?:Tool\w*|ActionBinding|CallProtocol|protocols|executionPolicy|directResultPolicy)\b', function_contract):
    errors.append('Callable ActionFunction must remain independent of registration/runtime protocols')
macro_implementation = (ROOT / 'Macros/BehaviorDefinitions/BehaviorDefinitionMacro.swift').read_text()
if 'ToolHandler' in macro_implementation or 'ToolCompletionHandler' in macro_implementation or 'ActionBinding' in macro_implementation:
    errors.append('@Action factories must bind canonical handlers only')
if (actions_root / 'ToolMacro.swift').exists():
    errors.append('Retired @Tool macro must not be recreated')
expected_domains = {'UI', 'Speech', 'Camera', 'History', 'System', 'NexArm'}
domains = {p.name for p in actions_root.iterdir() if p.is_dir()} - {'Support'}
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
            # System owns the neutral task-control host port; its public protocol address remains Agent.Task.
            expected_domain = 'Agent' if name == 'System' and expected_module == 'Task' else name
            if (declared_domain, declared_module) != (expected_domain, expected_module):
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
assembly = (ROOT / 'MobileHarness/Actions/Support/BehaviorAssembly.swift').read_text()
if 'CapabilityModules.builtIn' not in assembly or 'CapabilityCatalog(modules:' not in assembly or 'bindings.actions' not in assembly or 'bindings.tools' not in assembly or 'BehaviorProtocolBindings.bind' not in assembly:
    errors.append('BehaviorAssembly must project both registries from one business-domain catalog')
# Derive callable file ownership locally, without a second centralized per-function list.
for domain in expected_domains:
    facade = actions_root / domain / (domain + 'Actions.swift')
    if re.search(r'public static func', facade.read_text()):
        errors.append(f'Domain facade must not regain callable implementations: {domain}')
    for source in (actions_root / domain).glob('*.swift'):
        if not re.fullmatch(r'[A-Z][A-Za-z0-9]*Actions\.swift', source.name):
            errors.append(f'Noncanonical capability entry filename: {source.relative_to(ROOT)}')
        content = source.read_text()
        if source != facade and ('@Action(' not in content or not re.search(r'public static func', content)):
            errors.append(f'Empty or unregistered capability entry: {source.relative_to(ROOT)}')
if any((actions_root / 'Contracts' / name).exists() for name in ('FunctionMetadata.swift', 'FunctionMetadata.json')):
    errors.append('Retired centralized function metadata must not return')

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
# Explicit outer integration targets must not erase the independence of core modules.
expected_bindings = {
    'ActionBindings': {'Actions', 'AgentCore', 'FunctionContracts', 'ExecutionRuntime', 'CallRuntime', 'UI',
                       'PlatformKit', 'ModelKit', 'ModelKitRuntime', 'ModelKitDefaults', 'ModelKitOpenAI',
                       'ModelKitHub', 'Storage', 'StorageChat', 'StorageMedia', 'StorageAudio', 'StorageDevices'},
    'AgentBindings': {'Agents', 'AgentCore', 'Gateway', 'Actions', 'ActionBindings', 'FunctionContracts',
                      'ExecutionRuntime', 'CallRuntime', 'UI', 'PlatformKit', 'ModelKit', 'ModelKitRuntime',
                      'ModelKitDefaults', 'ModelKitHub', 'Storage', 'StorageChat', 'StorageMedia', 'StorageAudio',
                      'StorageTasks', 'StorageDevices'},
}
system_imports = {'Foundation', 'Observation', 'Synchronization', 'Security', 'UIKit', 'SwiftUI',
                  'CoreGraphics', 'AVFoundation', 'AVFAudio', 'OSLog'}
for name, allowed in expected_bindings.items():
    deps = {next(iter(d.values()))[0] for d in targets[name].get('dependencies', [])}
    if deps != allowed:
        errors.append(f'Unexpected {name} dependencies: {deps}')
    expected_root = ROOT / ('MobileHarness/Agents' if name == 'AgentBindings' else 'MobileHarness/Actions')
    for source in binding_sources[name]:
        if not source.is_relative_to(expected_root):
            errors.append(f'Integration source outside owning module: {source}')
        unexpected = imported_modules(source.read_text()) - allowed - system_imports
        if unexpected:
            errors.append(f'Forbidden {name} imports {unexpected}: {source.relative_to(ROOT)}')
for source in target_sources(targets['Agents']):
    if imported_modules(source.read_text()) & {'UI', 'Actions', 'Gateway', 'ActionBindings', 'AgentBindings', 'AppLifecycle'}:
        errors.append(f'Core Agents acquired integration dependency: {source.relative_to(ROOT)}')
for retired in ('AppWorkflows', 'AppSettingsWorkflow', 'AppHistoryWorkflow', 'AppBluetoothWorkflow',
                'AppPresentationWorkflow', 'AppSpeechPlayback', 'AppDiagnosticWorkflow', 'BehaviorAssembly'):
    if retired in targets:
        errors.append(f'Retired target remains: {retired}')
for retired in ('Adapters', 'Workflows', 'Composition/Behaviors'):
    if (ROOT / 'MobileHarness/App' / retired).exists():
        errors.append(f'Business directory remains in App: {retired}')
if targets['AppLifecycle'].get('dependencies'):
    errors.append('AppLifecycle must have no project dependencies')
for source in target_sources(targets['AppLifecycle']):
    if imported_modules(source.read_text()) - {'Foundation'}:
        errors.append(f'AppLifecycle acquired a domain dependency: {source.relative_to(ROOT)}')
for source in (ROOT / 'MobileHarness/App').rglob('*.swift'):
    if re.search(r'JSON(?:Encoder|Decoder)|\b(?:AgentInput|AgentTurn|FunctionInput|UIActions|ModelResourceIntent|PhotographerCameraIntent)\b|\b(?:switch destination|finishProviderSettings|resourcePreference|presentTranscript)\b', source.read_text()):
        errors.append(f'App contains business adaptation: {source.relative_to(ROOT)}')
# Execution integration submits UI-owned values through explicit public rendering methods.
for relative in (
    'Actions/Camera/Support/CameraCoordinator.swift',
    'Actions/UI/Support/ConversationPresentationController.swift',
    'Actions/Speech/Support/VoiceNativeEffects.swift',
    'Actions/System/Support/SpeechDiagnosticWorkflow.swift',
    'Actions/System/Support/SettingsProviderAdapter.swift',
    'Actions/System/Support/SettingsModelResourcesAdapter.swift',
    'Actions/History/Support/HistoryPresentationAdapter.swift',
):
    source = ROOT / 'MobileHarness' / relative
    if re.search(r'\bstate\.\w+\s*(?:=(?!=)|\+=)', source.read_text()):
        errors.append(f'Execution adapter writes UI internals: {relative}')
# Every production source has one package owner or is an executable-only App host source.
source_owners = {}
for name, target in targets.items():
    if target.get('type') != 'regular' or not target.get('path'):
        continue
    for source in target_sources(target):
        source_owners.setdefault(source, []).append(name)
for source in (ROOT / 'MobileHarness').rglob('*.swift'):
    owners = source_owners.get(source.resolve(), [])
    host_source = source.is_relative_to(ROOT / 'MobileHarness/App') and source.name != 'ApplicationLifecycle.swift'
    if len(owners) != (0 if host_source else 1):
        errors.append(f'Unexpected source owners {owners}: {source.relative_to(ROOT)}')
for root in ('UI', 'PlatformKit', 'ModelKit', 'Storage'):
    for source in (ROOT / 'MobileHarness' / root).rglob('*.swift'):
        if imported_modules(source.read_text()) & {'AgentBindings', 'ActionBindings', 'AppLifecycle'}:
            errors.append(f'Foundation depends on host integration: {source.relative_to(ROOT)}')
resource_assembly = (ROOT / 'MobileHarness/Agents/Support/ApplicationFeatures.swift').read_text()
if re.search(r'\.(?:downloadArtifact|cancelArtifact|removeArtifact)\(', resource_assembly):
    errors.append('Settings resource mutations must cross Agent/Gateway commands')
# Preference application must enter Agent routing; native lifecycle binding stays injected.
if 'applicationControlIntents.preferences(intent)' not in resource_assembly:
    errors.append('Preference restore/save must cross ApplicationControl')
preferences_facade = (ROOT / 'MobileHarness/Agents/ApplicationControl/ModelResourcesWorkflow.swift').read_text()
provider_facade = (ROOT / 'MobileHarness/Agents/ApplicationControl/SettingsWorkflow.swift').read_text()
if (ROOT / 'MobileHarness/App/Workflows/Settings/CloudSettingsStore.swift').exists():
    errors.append('Provider settings persistence belongs to Actions, not App workflows')
if re.search(r'provider\.prepare|store\.(?:load|save)\(|LocalDocumentStore', provider_facade):
    errors.append('Provider settings facade cannot own preparation or persistence transactions')
if re.search(r'LocalDocumentStore|\.(?:save|load)\(|\bnormalized\b', preferences_facade):
    errors.append('Settings preference facade cannot own persistence/normalization')
if 'intents.inventory()' not in resource_assembly or 'intents.presentInventory(generation: generation)' not in resource_assembly:
    errors.append('Resource refresh must cross ApplicationControl')
for source in binding_sources['AgentBindings']:
    if 'ModelResourcePolicy' in source.read_text():
        errors.append('Installed resource eligibility belongs to Actions inventory')
resource_interaction = (ROOT / 'MobileHarness/Agents/ApplicationControl/ModelResourceInteractionWorkflow.swift').read_text()
if re.search(r'state\.(?:items|installedGroups)\s*=', resource_interaction):
    errors.append('Resource refresh state commits must use registered presentation')
resource_agent = '\n'.join(source.read_text() for source in (ROOT / 'MobileHarness/Agents/ApplicationControl').glob('*.swift') if source.resolve() not in integration_sources)
if 'Camera.Capture.' in resource_agent:
    errors.append('Camera decisions/grants belong to Photographer, not ApplicationControl')
if set(re.findall(r'\bimport\s+(\w+)', resource_agent)) - {'AgentCore', 'Foundation', 'ModelKit', 'StorageChat', 'Storage'}:
    errors.append('ApplicationControl actor must remain independent of implementations')
# History transport is a narrow staged exception, not blanket feature policy access.
for source in (ROOT / 'MobileHarness/Agents/Memory').glob('*.swift'):
    if source.resolve() in integration_sources:
        continue
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    allowed = {'Foundation', 'AgentCore', 'ModelKit', 'StorageChat', 'Storage'} if source.name == 'ConversationTitleGenerator.swift' else {'Foundation', 'AgentCore', 'ModelKit', 'StorageChat', 'Storage'}
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
legacy_history = (ROOT / 'MobileHarness/Agents/Memory/ConversationHistoryWorkflow.swift').read_text()
if 'store.deleteArchived(' in legacy_history:
    errors.append('History mutation/inference bypasses the Agent capability path')
# Discovery/connection presentation must not consume device Action diagnostics.
bluetooth_view = (ROOT / 'MobileHarness/UI/Settings/BluetoothSettingsView.swift').read_text()
discovery_view = bluetooth_view.split('private struct BluetoothArmDetailView', 1)[0]
if re.search(r'\bstate\.(?:error|notice|incidents|motionStatus|executing|controlReady|controlValidated)\b', discovery_view):
    errors.append('Bluetooth discovery/connection UI consumes Action diagnostics or execution state')
# Device recovery must not acquire voice/session or scheduler cleanup.
bluetooth_sources = [ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmControlService.swift', ROOT / 'MobileHarness/Actions/NexArm/Support/BluetoothRecovery.swift']
for source in bluetooth_sources:
    if re.search(r'\b(?:quiesce|stopVoice|beginSettingsChange|synchronizeAgentControl|ChannelScheduler)\b', source.read_text()):
        errors.append(f'Bluetooth recovery depends on session/scheduler policy: {source.relative_to(ROOT)}')
bluetooth_workflow = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmControlService.swift').read_text()
disconnect_body = bluetooth_workflow.split('private func disconnect(', 1)[1].split('public func forget(', 1)[0]
if 'motion?.cancel()' in disconnect_body or 'movement.value' in disconnect_body:
    errors.append('Native disconnect must not cancel or join finite Agent Actions')
runtime = (ROOT / 'MobileHarness/Agents/Support/AgentServices.swift').read_text()
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
camera_ownership = (ROOT / 'MobileHarness/Actions/Camera/Support/CameraCoordinator.swift').read_text()
if '.faulted' in camera_ownership or 'resources.recover' in camera_ownership or 'recoverRequested' in camera_ownership:
    errors.append('Camera retry must acquire actual ownership without resource-fault recovery')
if 'preempts: [.assistant: [.photographer], .applicationControl: [.photographer]]' not in runtime or 'allowedOwners: [.assistant, .applicationControl, .photographer]' not in runtime or 'executionGroup:' not in runtime:
    errors.append('Composition must grant Assistant/fixed ApplicationControl writers joined takeover of Photographer')
if 'trackingInputAvailable' not in runtime or '[weak photographerAgent]' not in runtime or 'hasFreshPose()' not in runtime:
    errors.append('Tracking freshness must be bound to the current Photographer without retaining its lifetime')
assembly = (ROOT / 'MobileHarness/Agents/Support/ApplicationFeatures.swift').read_text()
bluetooth_binding = (ROOT / 'MobileHarness/App/Composition/ServiceFactories.swift').read_text()
if 'stopVoice' in bluetooth_binding or 'beginSettingsChange' in bluetooth_binding:
    errors.append('Bluetooth construction cannot bind whole voice/session cleanup')
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
    if source.resolve() in integration_sources:
        continue
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - {'Foundation', 'FunctionContracts', 'StorageChat', 'Storage'}:
        errors.append(f'History Tools have non-foundational imports: {source.relative_to(ROOT)}')
# Feature-specific presentation contracts must not return to Agent infrastructure.
if (ROOT / "MobileHarness/Agents/Support/Core/Output/PoseOverlay.swift").exists():
    errors.append("PoseOverlay belongs to UI/Camera, not AgentCore")

# Xcode navigation must not point to retired role assets or moved Support sources.
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(ROOT / 'MobileHarness.xcodeproj/project.pbxproj')
], text=True))
for item in project['objects'].values():
    path = item.get('path', '')
    if item.get('isa') == 'PBXFileReference' and path.startswith('MobileHarness/Agents/') and not (ROOT / path).is_file():
        errors.append(f'Stale Xcode Agent navigation reference: {path}')

# Source naming and shared-component ownership are architectural contracts.
for source in (ROOT / 'MobileHarness').rglob('*.swift'):
    if not re.fullmatch(r'[A-Z][A-Za-z0-9]*\.swift', source.name):
        errors.append(f'Swift source must use UpperCamelCase: {source.relative_to(ROOT)}')
support = ROOT / 'MobileHarness/Agents/Support'
for source in support.glob('*.swift'):
    if source.resolve() in integration_sources:
        continue
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports - {'Foundation', 'AgentCore', 'FunctionContracts'}:
        errors.append(f'Support root must remain immutable configuration/catalog helpers: {source.name}')
for filename in ['AgentConfigurations.swift', 'AgentSkillLoader.swift']:
    if not (support / filename).is_file():
        errors.append(f'Missing Support configuration helper: {filename}')
for filename in ['AgentTaskSkillState.swift', 'AgentFixedTaskCoordinator.swift']:
    if not (support / 'Context' / filename).is_file():
        errors.append(f'Task context/lifecycle must belong to Context: {filename}')
for source in (support / 'Communication').glob('*.swift'):
    if source.resolve() in integration_sources:
        continue
    if re.search(r'\b(?:AgentContextRepository|AgentTaskSkillState|AgentFixedTaskCoordinator|AgentSkillLoader|AgentConfigurations)\b', source.read_text()):
        errors.append(f'Communication content cannot own resources or context lifecycle: {source.name}')

# Physical consolidation preserves distinct framework/contracts/capability/persistence layers.
for layer, allowed in {
    'Core': {'Foundation', 'Storage'},
    'Communication': {'Foundation', 'AgentCore', 'FunctionContracts', 'Storage'},
    'Context': {'Foundation', 'AgentCore', 'Storage'},
    'Chat': {'Foundation', 'AgentCore', 'ModelKit', 'StorageChat', 'StorageTasks', 'Storage'},
}.items():
    for source in (ROOT / 'MobileHarness/Agents/Support' / layer).rglob('*.swift'):
        if source.resolve() in integration_sources:
            continue
        imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
        if imports - allowed:
            errors.append(f'Forbidden Support/{layer} imports {sorted(imports - allowed)}: {source.relative_to(ROOT)}')

for source in (support / 'Chat').glob('*.swift'):
    if re.search(r'\b(?:AssistantContextState|AssistantContextBuilder|PhotographerAgent|MemoryAgent|ApplicationControlAgent|CameraStateObservation)\b', source.read_text()):
        errors.append(f'Shared Chat must not interpret a concrete role schema: {source.name}')

# Core owns generic contracts, never built-in application Agents or speech policy.
core_dependencies = [next(iter(d.values()))[0] for d in targets['AgentCore'].get('dependencies', [])]
if core_dependencies:
    errors.append('AgentCore must remain an independent runtime contract target')
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
    if set(imports) - {'Foundation', 'ModelKit', 'Storage'}:
        errors.append(f'{name} must not import transport, UI or device modules')
if (speech_root / 'LiveSpeechInput.swift').exists():
    errors.append('Obsolete LiveSpeechInput must not duplicate SpeechRecognitionTurn')

sound_estimator = ROOT / 'MobileHarness/Agents/SpeechPerception/SoundSourceEstimator.swift'
if not sound_estimator.exists() or set(re.findall(r'^import (\w+)', sound_estimator.read_text(), re.MULTILINE)) - {'Foundation'}:
    errors.append('SoundSourceEstimator must remain pure Foundation-only Agent policy')

# Settings diagnostics delegates whole session work to Lifecycle; never duplicate capture or DSP here.
audio_workflow = ROOT / 'MobileHarness/UI/Diagnostics/AudioDetectionWorkflow.swift'
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
input_contract = (actions_root / 'Support/Contracts/FunctionInput.swift').read_text()
request_contract = (actions_root / 'Support/Contracts/FunctionRequest.swift').read_text()
if 'public protocol FunctionInput: Sendable' not in input_contract or re.search(r'\b(?:channel|protocols|ActionRequest|ToolRequest)\b', request_contract):
    errors.append('Function contracts must expose standard input without call protocol or Channel')
for source in actions_root.glob('*/Support/*Module.swift'):
    if ': CapabilityModule' in source.read_text() and 'public var definitions:' not in source.read_text():
        errors.append(f'Domain lacks canonical executable catalog: {source.relative_to(ROOT)}')

for registry in ('ActionRegistry.swift', 'ToolRegistry.swift'):
    if 'definition.validate()' not in (ROOT / 'MobileHarness/Gateway/Output/Registration' / registry).read_text():
        errors.append(f'Registry must use shared executable metadata validation: {registry}')
if targets['Agents'].get('path') != 'MobileHarness' or targets['Agents'].get('sources') != ['Agents']:
    errors.append('Agents must compile only Agents sources while packaging shared assets')
asset_root = ROOT / 'MobileHarness/Resources'
asset_catalog = json.loads((asset_root / 'Catalog.json').read_text())
for group, version in [('agents', 7), ('skills', 1)]:
    for name, relative in asset_catalog[group].items():
        source = asset_root / relative
        parts = Path(relative).parts
        if parts[0] != group.title() or source.name != ('Agent.json' if group == 'agents' else 'Skill.json') or not re.fullmatch(r'[A-Z][A-Za-z0-9]*', parts[1]):
            errors.append(f'Noncanonical Agent/Skill resource name: {relative}')
        if not source.resolve().is_relative_to(asset_root.resolve()):
            errors.append(f'Unconfined Agent resource: {relative}')
            continue
        configuration = json.loads(source.read_text())
        if configuration.get('version') != version:
            errors.append(f'Invalid {group} version: {relative}')
        if group == 'agents':
            actor = ROOT / 'MobileHarness/Agents' / name / f'{name}Agent.swift'
            if not actor.is_file(): errors.append(f'Missing canonical Agent: {name}')
            if 'permissions' in configuration or (source.parent / 'Permissions.json').exists():
                errors.append(f'Retired per-Agent Permissions remain: {relative}')
            if any(key in configuration for key in ('functions', 'actions', 'tools')):
                errors.append(f'Agent function registration must belong to Skills: {relative}')
            base = configuration.get('baseSkills', [])
            if not isinstance(base, list) or any(skill not in asset_catalog['skills'] for skill in base):
                errors.append(f'Unknown Agent base Skill: {relative}')
            functions = []
        elif group == 'skills': functions = configuration['functions']
        else: continue
        paths = [f['path'] for f in functions]
        aliases = [f['alias'] for f in functions]
        if len(paths) != len(set(paths)) or len(aliases) != len(set(aliases)):
            errors.append(f'Duplicate function registration: {relative}')
        for function in functions:
            if len(function['path'].split('.')) != 3 or function['callType'] not in ('action', 'tool'):
                errors.append(f'Invalid function binding: {relative}')
            if function['path'] == 'Agent.Communication.send' and function['callType'] != 'action':
                errors.append(f'send must be Action: {relative}')
if any(p for group in ('Agents', 'Skills') for p in (asset_root / group).rglob('*.swift')):
    errors.append('Agent Resources must not contain compiled code')
if any((ROOT / 'MobileHarness/Agents').rglob('*.agent.json')):
    errors.append('Retired Agent configuration remains outside Resources')
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
for source in list(binding_sources['AgentBindings']) + [ROOT / 'MobileHarness/Agents/Support/MediaInputAdapter.swift']:
    if re.search(r'\bImageFrame\s*\(|\bStreamingMonoPCMResampler\s*\(', source.read_text()):
        raise SystemExit(f'Model input preparation belongs to the calling Agent: {source.relative_to(ROOT)}')
if 'resolveImage:' in (ROOT / 'MobileHarness/Agents/Support/ApplicationFeatures.swift').read_text():
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
manual_workflow = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmControlService.swift').read_text()
manual_section = manual_workflow.split('public func tryAction', 1)[1].split('private func joinCancelledControl', 1)[0]
if 'controller.performPlan' not in manual_section or 'plan.submit' in manual_section or 'link.sendLive' in manual_section:
    raise SystemExit('Settings presets must reuse Actions segment-feedback execution.')
plan_source = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmMotionPlan.swift').read_text()
if 'Task.sleep' in plan_source:
    raise SystemExit('Motion recipes must not implement nominal-frame playback sleeps.')
print('Settings presets reuse Actions segment feedback under cancellable module ownership.')

connect_source = manual_workflow.split('public func connect', 1)[1].split('public func disconnect', 1)[0]
if any(probe in connect_source for probe in ('verifyCompatibility(', 'prepareArmControl(', 'indicateConnection(', 'readState(')):
    raise SystemExit('App BLE connection must use passive feedback without active probes.')
print('NexArm connection uses native subscription and passive feedback.')

# Native diagnostics and execution results have independent owners and effects.
execution_section = manual_workflow.split('public func tryAction', 1)[1]
if any(marker in execution_section for marker in ('recordIncident(', 'appendIncident(', 'recordConnectionEvent(', 'recordLifecycleEvent(', 'recordRecoveryEvent(', 'requestRecovery(', 'state.error =', 'state.transportIssue =', 'state.notice =', 'handleControlFailure', 'stalledSince')):
    raise SystemExit('Execution/manual control must not write Bluetooth diagnostics or initiate recovery.')
recovery_source = (ROOT / 'MobileHarness/Actions/NexArm/Support/BluetoothRecovery.swift').read_text()
if re.search(r'\b(?:import Actions|NexArmActionError|NexArmExecutionError|case resources)\b', recovery_source):
    raise SystemExit('Bluetooth recovery must not depend on Action failures/resources.')
if 'BluetoothSettingsState' in (ROOT / 'MobileHarness/UI/Conversation/ConversationView.swift').read_text():
    raise SystemExit('Home conversation must not observe Bluetooth state.')
for filename in ('Actions/UI/Support/RuntimePresentation.swift', 'Actions/Camera/Support/CameraCoordinator.swift', 'UI/Camera/CameraState.swift'):
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
adapter_source = (ROOT / 'MobileHarness/Actions/NexArm/Support/NexArmBehaviorAdapter.swift').read_text()
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
if 'typealias FailureCode = ActionExecutionFailureCode' not in tool_contract or 'ActionExecutionFailureProviding' not in (actions_root / 'Support/Contracts/ActionExecutionFailure.swift').read_text():
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
observer_source = (ROOT / 'MobileHarness/PlatformKit/Core/ResourceObservationWorkflow.swift').read_text()
if set(re.findall(r'\bimport\s+(\w+)', observer_source)) - {'Foundation'}:
    raise SystemExit('Resource observation must remain an injected input adapter.')


# Runtime business state is memory-owned; only normalized record repositories are durable.
for owner in ('App', 'Agents'):
    for source in (ROOT / 'MobileHarness' / owner).rglob('*.swift'):
        text = source.read_text()
        if 'LocalDocumentStore<AgentContext' in text or '.runtime-context.json' in text:
            raise SystemExit(f'{source}: Agent runtime state must not use JSON files.')
context_repository = (ROOT / 'MobileHarness/Agents/Support/Context/AgentContextRepository.swift').read_text()
if 'MemoryStateStore' not in context_repository or 'StateRepository<AgentContext<State>>' not in context_repository:
    raise SystemExit('Agent runtime state must use the Storage memory-state contract.')
if 'ContextDocumentAdapter' in context_repository or 'AssistantConversationRecovery' in (ROOT / 'MobileHarness/Agents/Assistant/AssistantProcessing.swift').read_text():
    raise SystemExit('Retired Context JSON adapters and duplicate Task recovery blobs must stay removed.')
print('Runtime memory-state and database record lifecycle boundaries pass.')

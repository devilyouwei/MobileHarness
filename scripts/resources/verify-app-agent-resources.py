#!/usr/bin/env python3
"""Verify final app Agent declarations and prompt resources against source bytes."""
import pathlib
import json
import re
import sys
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
app = pathlib.Path(sys.argv[1])


source = root / 'MobileHarness/Agents/Resources'
bundle = app / 'HarnessKit_Agents.bundle'
# Exercise Foundation Bundle lookup, not just filesystem presence: iOS resourceURL
# may already select a Resources directory inside a resource bundle.
lookup = subprocess.check_output([
    'swift', '-e',
    'import Foundation; '
    'guard let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments.last!)), '
    'let catalog = bundle.url(forResource: "Catalog", withExtension: "json") '
    'else { fatalError("Packaged Agent catalog is not discoverable through Bundle") }; '
    'print(catalog.standardizedFileURL.path)',
    str(bundle.resolve()),
], text=True).strip()
if pathlib.Path(lookup).resolve() != (bundle / 'Catalog.json').resolve():
    raise SystemExit(f'Unexpected Bundle catalog lookup: {lookup}')
expected = {pathlib.Path('Catalog.json'): source / 'Catalog.json'}
for group in ('Agents', 'Skills'):
    expected.update({p.relative_to(source): p for p in (source / group).rglob('*') if p.is_file()})
for name in ('OutputProtocol.md', 'ActionCatalog.json', 'SkillCatalog.json', 'AgentCatalog.json', 'StateContext.json', 'ControlCatalog.json'):
    path = pathlib.Path('Agents/Shared') / name
    if path not in expected:
        raise SystemExit(f'Missing Shared prompt source: {path}')
signature_metadata = {
    pathlib.Path('_CodeSignature') / name
    for name in ('CodeResources', 'CodeRequirements', 'CodeDirectory', 'CodeSignature')
}
actual = {
    p.relative_to(bundle): p for p in bundle.rglob('*')
    if p.is_file() and p.name != 'Info.plist' and p.relative_to(bundle) not in signature_metadata
}
if set(expected) != set(actual):
    raise SystemExit(f'Agent asset mismatch: missing={set(expected)-set(actual)}, stale={set(actual)-set(expected)}')
for path, original in expected.items():
    if original.read_bytes() != actual[path].read_bytes():
        raise SystemExit(f'Stale Agent asset: {path}')
keyword_assets = {
    pathlib.Path('Agents/SpeechPerception/ZipformerKeywords.json'),
    pathlib.Path('Agents/Assistant/Input/InterruptionKeywords.json'),
}
if not keyword_assets.issubset(expected):
    raise SystemExit(f'Missing speech keyword assets: {keyword_assets - expected.keys()}')
for path, original in expected.items():
    if '.zh-Hans.' in path.name or path in keyword_assets:
        continue
    if path.suffix not in ('.json', '.md') or path.name in ('Agent.json', 'Skill.json', 'Catalog.json'):
        continue
    translated = path.with_name(f'{path.stem}.zh-Hans{path.suffix}')
    if translated not in expected:
        raise SystemExit(f'Missing Simplified Chinese prompt: {path}')
    if path.suffix == '.md':
        continue
    source_templates = json.loads(original.read_text()).get('templates')
    if source_templates is None:  # Structured libraries such as Controls.json have no prompt templates.
        continue
    translated_templates = json.loads(expected[translated].read_text())['templates']
    if source_templates.keys() != translated_templates.keys():
        raise SystemExit(f'Template key mismatch: {path}')
    for key, template in source_templates.items():
        placeholders = r'\{\{([A-Za-z0-9_.]+)\}\}'
        if set(re.findall(placeholders, template)) != set(re.findall(placeholders, translated_templates[key])):
            raise SystemExit(f'Template placeholder mismatch: {path}:{key}')
catalog = json.loads((bundle / 'Catalog.json').read_text())
for group in ('agents', 'skills'):
    for path in catalog[group].values():
        config = bundle / path
        if 'description' in json.loads(config.read_text()):
            raise SystemExit(f'Public prose belongs in Description.md: {path}')
        for name in ('Description.md', 'Description.zh-Hans.md'):
            description = config.with_name(name)
            text = description.read_text(encoding='utf-8').strip()
            if not text or (group == 'agents' and len(text.encode('utf-8')) > 2048):
                raise SystemExit(f'Invalid public description: {description}')
for name in ('Input/InputProtocol.json', 'Input/InputDecision.json', 'Controls/Controls.json', 'Controls/Controls.md', 'Prompts.json', 'Instructions.md'):
    if not (bundle / 'Agents/Assistant' / name).is_file():
        raise SystemExit(f'Missing Assistant prompt resource: {name}')
writer = bundle / 'Agents/Writer'
for name in ('Instructions.md', 'Prompts.json', 'ContentPrompts.json', 'Recovery.json', 'WorkspaceFeedback.json'):
    if not (writer / name).is_file():
        raise SystemExit(f'Missing Writer prompt resource: {name}')
for name in ('ControlContext.json', 'ContentContext.json', 'ContentInstructions.md'):
    if (writer / name).exists():
        raise SystemExit(f'Retired Writer prompt remains packaged: {name}')
if (bundle / 'Agents/System').exists():
    raise SystemExit('Retired System prompt directory remains packaged')
# Action translations are owned and packaged by the Actions target.
action_source = root / 'MobileHarness/Actions/Resources/Localization'
action_bundle = app / 'HarnessKit_Actions.bundle'
action_expected = {p.relative_to(action_source): p for p in action_source.rglob('*') if p.is_file()}
action_actual = {
    p.relative_to(action_bundle / 'Localization'): p
    for p in (action_bundle / 'Localization').rglob('*') if p.is_file()
}
if set(action_expected) != set(action_actual):
    raise SystemExit(f'Action localization mismatch: missing={set(action_expected)-set(action_actual)}, stale={set(action_actual)-set(action_expected)}')
for path, original in action_expected.items():
    if original.read_bytes() != action_actual[path].read_bytes():
        raise SystemExit(f'Stale Action localization: {path}')
for owner in ('ModelKit',):
    if (app / f'HarnessKit_{owner}.bundle').exists():
        raise SystemExit(f'Retired {owner} prompt bundle remains packaged')
if list(app.rglob('FunctionTokenPrompts.json')):
    raise SystemExit('Retired Core protocol resource remains packaged')
if list(app.rglob('FunctionMetadata.json')):
    raise SystemExit('Retired centralized function metadata remains packaged')
print(f'Final app Agent/Skill resources verified: {len(expected)} assets, including Shared protocols, role contexts.')

#!/usr/bin/env python3
"""Verify final app Agent declarations and prompt resources against source bytes."""
import pathlib
import sys
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])


source = root / 'MobileHarness/Resources'
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
for name in ('InputProtocol.md', 'OutputProtocol.md', 'ActionCatalog.json', 'SkillCatalog.json', 'AgentCatalog.json', 'RequestContext.json'):
    path = pathlib.Path('Agents/System') / name
    if path not in expected:
        raise SystemExit(f'Missing System prompt source: {path}')
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
if list(app.rglob('FunctionTokenPrompts.json')):
    raise SystemExit('Retired Core protocol resource remains packaged')
if list(app.rglob('FunctionMetadata.json')):
    raise SystemExit('Retired centralized function metadata remains packaged')
print(f'Final app Agent/Skill resources verified: {len(expected)} assets, including System protocols and Action catalog templates.')

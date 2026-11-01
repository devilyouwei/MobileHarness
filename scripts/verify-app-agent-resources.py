#!/usr/bin/env python3
"""Verify final app Agent declarations and prompt resources against source bytes."""
import pathlib
import sys
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])


def verify(bundle, expected):
    actual = {p.name: p for p in bundle.glob('*.json')}
    if set(expected) != set(actual):
        raise SystemExit(f'{bundle.name} resource mismatch: missing={sorted(set(expected)-set(actual))}, stale={sorted(set(actual)-set(expected))}')
    for name, source in expected.items():
        if source.read_bytes() != actual[name].read_bytes():
            raise SystemExit(f'Stale packaged resource: {name}')
    return len(expected)


agents = root / 'MobileHarness/Agents'
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
core = agents / 'Support/Core/Generation/FunctionTokenPrompts.json'
verify(app / 'HarnessKit_AgentCore.bundle', {core.name: core})
if list(app.rglob('FunctionMetadata.json')):
    raise SystemExit('Retired centralized function metadata remains packaged')
print(f'Final app Skill resources verified: {len(expected)} assets; Core protocol; function declarations compiled with Actions.')

#!/usr/bin/env python3
"""Verify final app Agent configs against their single source of truth."""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])
bundle = app / 'HarnessKit_Agents.bundle'
expected = {p.name: p for p in (root / 'MobileHarness/Agents').rglob('*.agent.json')}
actual = {p.name: p for p in bundle.glob('*.agent.json')}
if set(expected) != set(actual):
    raise SystemExit(f'Agent package mismatch: missing={sorted(set(expected)-set(actual))}, stale={sorted(set(actual)-set(expected))}')
for name, source in expected.items():
    if source.read_bytes() != actual[name].read_bytes():
        raise SystemExit(f'Stale packaged Agent configuration: {name}')
print(f'Final app Agent resources verified: {len(expected)} configs.')

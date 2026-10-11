#!/usr/bin/env python3
"""Verify final app Agent declarations and prompt resources against source bytes."""
import pathlib
import sys

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
expected = {p.name: p for p in agents.rglob('*.agent.json')}
expected.update({p.name: p for p in agents.glob('*/*.prompts.json')})
agent_count = verify(app / 'HarnessKit_Agents.bundle', expected)
core = agents / 'Support/Core/Generation/FunctionToken.prompts.json'
core_count = verify(app / 'HarnessKit_AgentCore.bundle', {core.name: core})
print(f'Final app Agent resources verified: {agent_count} declarations/prompts; {core_count} protocol resource.')

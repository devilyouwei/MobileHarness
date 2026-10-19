import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('protocol_probe', Path(__file__).resolve().parent.parent / 'scripts/compare-qwen-protocols.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def message(text):
    return {'type': 'message', 'content': [{'type': 'output_text', 'text': text}]}


def native(alias, arguments='{}'):
    name = next(k for k, v in probe.WIRE.items() if v == alias)
    return {'type': 'function_call', 'name': name, 'arguments': arguments, 'call_id': 'synthetic-call'}


class ProtocolComparisonTests(unittest.TestCase):
    def test_same_semantics_are_partitioned_without_overlapping_declarations(self):
        for mode in probe.MODES:
            native_aliases = {probe.WIRE[t['name']] for t in probe.declarations(mode)}
            xml_aliases = {a for a in probe.BY_ALIAS if probe.xml_allowed(mode, a)}
            self.assertFalse(native_aliases & xml_aliases)
            self.assertEqual(native_aliases | xml_aliases, set(probe.BY_ALIAS))
        self.assertEqual(probe.declarations('xml-only'), [])
        self.assertEqual(len(probe.declarations('native-only')), 7)

    def test_a_response_can_contain_both_valid_protocols(self):
        calls, issues, _, mixed = probe.classify('mixed', [message('<closeCamera/>'), native('Provider.readSettings')])
        self.assertEqual(issues, [])
        self.assertTrue(mixed)
        self.assertEqual({c['alias'] for c in calls}, {'closeCamera', 'Provider.readSettings'})
        self.assertIn('mixedDespiteExclusive', probe.classify('mixed-exclusive', [message('<closeCamera/>'), native('Provider.readSettings')])[1])

    def test_wrong_channel_name_identity_and_json_shape_fail(self):
        cases = [
            ('mixed', [native('closeCamera')], 'undeclaredNative:'),
            ('mixed', [message('<Provider.readSettings/>')], 'undeclaredXML:'),
            ('native-only', [native('Provider.readSettings', '{"private":7}')], 'parameterTypes:'),
            ('xml-only', [message('<openPage destination="outside"/>')], 'parameterValue:'),
            ('xml-only', [message('<closeCamera></closeCamera>')], 'nonSelfClosingXML:'),
        ]
        for mode, items, prefix in cases:
            with self.subTest(mode=mode, prefix=prefix):
                self.assertTrue(any(i.startswith(prefix) for i in probe.classify(mode, items)[1]))
        bad = native('Provider.readSettings'); bad['name'] = 'Provider_readSettings'
        self.assertTrue(probe.classify('mixed', [bad])[1])
        bad = native('Provider.readSettings'); bad.pop('call_id')
        self.assertTrue(probe.classify('mixed', [bad])[1])

    def test_followup_contains_paired_feedback_and_does_not_retry_effect(self):
        case = next(c for c in probe.CASES if c['id'] == 'scan-then-read')
        seen = []
        def request(endpoint, key, payload):
            seen.append(payload)
            if len(seen) == 1:
                return {'status': 'completed', 'output': [message('<Bluetooth.control operation="scan"/>')]}, None
            self.assertTrue(payload['input'][-1]['content'].startswith('Execution observations'))
            return {'status': 'completed', 'output': [native('Bluetooth.readStatus')]}, None
        original = probe.safe_request
        try:
            probe.safe_request = request
            result = probe.trial('qwen3.8-flash', 'mixed', case, 0, '', '', [0])
            self.assertTrue(result['passed']); self.assertEqual(len(result['records']), 2)
            seen.clear()
            def duplicate(*_):
                return {'status': 'completed', 'output': [message('<Bluetooth.control operation="scan"/>')]}, None
            probe.safe_request = duplicate
            result = probe.trial('qwen3.8-flash', 'mixed', case, 0, '', '', [0])
            self.assertIn('repeatedCall', result['issues'])
            self.assertEqual(len(result['records']), 2)
        finally:
            probe.safe_request = original

    def test_native_followup_uses_original_call_id_and_order_is_explicit(self):
        case = next(c for c in probe.CASES if c['id'] == 'read-then-open')
        seen = []
        def request(endpoint, key, payload):
            seen.append(payload)
            if len(seen) == 1:
                return {'status': 'completed', 'output': [native('Provider.readSettings')]}, None
            self.assertEqual(payload['input'][-1]['type'], 'function_call_output')
            self.assertEqual(payload['input'][-1]['call_id'], 'synthetic-call')
            return {'status': 'completed', 'output': [message('<openPage destination="settings"/>')]}, None
        original = probe.safe_request
        try:
            probe.safe_request = request
            self.assertTrue(probe.trial('qwen3.8-flash', 'mixed', case, 0, '', '', [0])['passed'])
            def both(*_):
                return {'status': 'completed', 'output': [native('Provider.readSettings'), message('<openPage destination="settings"/>')]}, None
            probe.safe_request = both
            result = probe.trial('qwen3.8-flash', 'mixed', case, 0, '', '', [0])
            self.assertIn('dependencyNotAwaited', result['issues'])
        finally:
            probe.safe_request = original


if __name__ == '__main__':
    unittest.main()

"""Small Python-only model transports. No App composition or automatic downloads."""
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_report(path, report, *, first=False):
    path = Path(path)
    if first:
        with path.open('x') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
    else:
        temporary = path.with_name(path.name + '.tmp')
        with temporary.open('w') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
        temporary.replace(path)


def positive(value):
    value = int(value)
    if value < 1:
        raise ValueError('Expected a positive integer')
    return value


class CloudChat:
    def __init__(self, config, timeout=90):
        from urllib.parse import urlsplit
        self.model = config['model']
        self.endpoint = config['endpoint'].rstrip('/')
        if urlsplit(self.endpoint).scheme not in ('https', 'http'):
            raise ValueError('Expected an HTTP(S) model endpoint')
        self.key = os.environ[config['api_key_env']]
        if not self.key:
            raise ValueError('Empty API key')
        self.timeout = timeout
        self.options = config.get('options', {})
        if not isinstance(self.options, dict):raise ValueError('Expected an options object')
        if set(self.options) & {'model', 'messages', 'stream'}:
            raise ValueError('Model options cannot override request identity')

    async def chat(self, messages):
        def request():
            payload = dict(self.options, model=self.model, messages=messages, stream=False)
            req = urllib.request.Request(self.endpoint + '/chat/completions',
                json.dumps(payload).encode(), {'Authorization': 'Bearer ' + self.key,
                                              'Content-Type': 'application/json'})
            try:
                class NoRedirects(urllib.request.HTTPRedirectHandler):
                    def redirect_request(self, request, fp, code, message, headers, target):
                        raise ValueError('Model endpoint redirects are not supported')
                with urllib.request.build_opener(NoRedirects()).open(req, timeout=self.timeout) as response:
                    raw = response.read(32 * 1024 * 1024 + 1)
            except urllib.error.HTTPError as error:
                raise RuntimeError(f'Model HTTP {error.code}') from None
            except urllib.error.URLError:
                raise RuntimeError('Model transport failed') from None
            if len(raw) > 32 * 1024 * 1024:
                raise ValueError('Model response exceeded 32 MiB')
            data = json.loads(raw)
            message = data['choices'][0]['message']
            content = message.get('content')
            if not isinstance(content, str):
                raise ValueError('Expected a text completion')
            return dict(text=content, usage=data.get('usage'),
                        finishReason=data['choices'][0].get('finish_reason'))
        return await asyncio.to_thread(request)


class AppleChat:
    async def chat(self, messages):
        import apple_fm_sdk as fm
        system = '\n'.join(m['content'] for m in messages if m['role'] == 'system')
        # Each experiment request gets an isolated session; all supplied history is explicit.
        prompt = '\n\n'.join(f"{m['role']}: {m['content']}" for m in messages if m['role'] != 'system')
        model = fm.SystemLanguageModel()
        available, reason = model.is_available()
        if not available:raise RuntimeError('Apple system model unavailable: ' + str(reason))
        session = fm.LanguageModelSession(model=model, instructions=system)
        response = await session.respond(prompt)
        return dict(text=str(response), finishReason='completed')


class CoreAIChat:
    def __init__(self, config):
        self.config = config
        self.decoder = None

    async def chat(self, messages):
        from transformers import AutoTokenizer
        from .coreai_decoder import Decoder
        if self.decoder is None:
            self.tokenizer = AutoTokenizer.from_pretrained(self.config['tokenizer'], local_files_only=True)
            self.decoder = await Decoder.load(self.config)
        if self.config.get('template') == 'gemma4':
            prompt = '<bos>' + ''.join('<|turn>' + ('model' if m['role']=='assistant' else m['role']) + '\n' + m['content'] + '<turn|>\n' for m in messages) + '<|turn>model\n'
            ids = self.tokenizer.encode(prompt, add_special_tokens=False)
        else:
            prompt = self.tokenizer.apply_chat_template(messages, tokenize=False,
                add_generation_prompt=True, enable_thinking=False)
            ids = self.tokenizer.encode(prompt, add_special_tokens=False)
        stops = set(self.config.get('stop_tokens', []))
        vocab = self.tokenizer.get_vocab()
        stops.update(vocab[t] for t in self.config.get('stop_strings', []) if t in vocab)
        if self.tokenizer.eos_token_id is not None:
            stops.add(self.tokenizer.eos_token_id)
        output = await self.decoder.generate(ids, self.config.get('max_tokens', 512), stops)
        return dict(text=self.tokenizer.decode(output['tokens'], skip_special_tokens=True),
                    inputTokens=len(ids), outputTokens=len(output['tokens']),
                    finishReason='stop' if output['stopped'] else 'length')


async def chat_model(config, timeout=90):
    kind = config['backend']
    if kind == 'cloud':
        return CloudChat(config, timeout)
    if kind == 'apple':
        return AppleChat()
    if kind == 'coreai':
        return CoreAIChat(config)
    raise ValueError(f'Unknown chat backend: {kind}')


def summary(rows):
    elapsed = sorted(r['milliseconds'] for r in rows if 'error' not in r)
    scored = [r for r in rows if r.get('scored', True)]
    return dict(count=len(rows), scored=len(scored), excluded=len(rows)-len(scored),
                passed=sum(r.get('passed', False) for r in scored),
                errors=sum('error' in r for r in rows),
                p50MS=elapsed[math.ceil(len(elapsed) * .5) - 1] if elapsed else None,
                p95MS=elapsed[math.ceil(len(elapsed) * .95) - 1] if elapsed else None)


async def run_cases(cases, evaluate, output, *, timeout=90, provenance=None):
    if not cases:
        raise ValueError('Empty case selection')
    report = dict(version=1, scope='Python model-case evaluation; no App execution',
                  provenance=provenance or {}, rows=[], complete=False)
    write_report(output, report, first=True)
    for case in cases:
        start = time.perf_counter()
        row = dict(id=case['id'])
        try:
            row.update(await asyncio.wait_for(evaluate(case), timeout))
        except Exception as error:
            # Transport failures must not emit credentials or provider response bodies.
            row.update(passed=False, error=type(error).__name__)
        row['milliseconds'] = (time.perf_counter() - start) * 1000
        report['rows'].append(row)
        report['summary'] = summary(report['rows'])
        write_report(output, report)
    report['complete'] = True
    write_report(output, report)
    return int(any('error' in r or (r.get('scored', True) and not r.get('passed', False)) for r in report['rows']))

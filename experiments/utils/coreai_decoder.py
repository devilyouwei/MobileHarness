"""Greedy Python decoding of Apple's sequential input_ids/position_ids graph contract."""
from pathlib import Path
import numpy as np
from coreai.runtime import AIModel, NDArray, SpecializationOptions


class Decoder:
    @classmethod
    async def load(cls, config):
        self = cls()
        self.capacity = int(config.get('context_length', 512))
        self.model = await AIModel.load(config['graph'], SpecializationOptions.default())
        self.function = self.model.load_function(config.get('function', 'main'))
        desc = self.function.desc
        static = config.get('static_inputs', {})
        if set(desc.input_names) != {'input_ids', 'position_ids'} | set(static) or not desc.state_names:
            raise ValueError('Expected a stateful sequential language graph')
        self.output = config.get('output', desc.output_names[0])
        self.static = {}
        self.backings = []
        for name, item in static.items():
            dtype = np.dtype(item['dtype']); shape = item['shape']; path = Path(item['path'])
            if path.stat().st_size != int(np.prod(shape)) * dtype.itemsize:
                raise ValueError(f'Static input size mismatch: {name}')
            backing = np.memmap(path, dtype=dtype, mode='r', shape=tuple(shape))
            self.backings.append(backing); self.static[name] = NDArray(backing)
        self.states = {}
        for name in desc.state_names:
            spec = desc.state_descriptor(name)
            shape = config.get('state_shapes', {}).get(name, [self.capacity if n == -1 else n for n in spec.shape])
            if any(not isinstance(n, int) or n < 1 for n in shape):
                raise ValueError(f'Set state_shapes for symbolic state {name}')
            dtype = config.get('state_dtypes', {}).get(name, spec.dtype)
            self.states[name] = (shape, np.dtype(dtype))
        return self

    async def generate(self, ids, max_tokens, stops, candidates=()):
        if not ids or max_tokens < 1 or len(ids) + max_tokens > self.capacity:
            raise ValueError('Input/output exceeds the configured context window')
        state = {name: NDArray(np.zeros(shape, dtype=dtype)) for name, (shape, dtype) in self.states.items()}
        tokens, scores = [], []
        # One token per step works for fixed-one and dynamic sequential graphs.
        position = 0
        logits = None
        for token in ids:
            output = await self.function({**self.static, 'input_ids': NDArray(np.array([[token]], dtype=np.int32)),
                'position_ids': NDArray(np.array([list(range(position + 1))], dtype=np.int32))}, state=state)
            logits = output[self.output].numpy().reshape(-1)
            position += 1
        for index in range(max_tokens):
            if not np.isfinite(logits).all():
                raise ValueError('Nonfinite model logits')
            if index == 0:
                scores = [float(logits[c]) for c in candidates]
            token = int(logits.argmax())
            if token in stops:
                return dict(tokens=tokens, scores=scores, stopped=True)
            tokens.append(token)
            if index + 1 < max_tokens:
                output = await self.function({**self.static, 'input_ids': NDArray(np.array([[token]], dtype=np.int32)),
                    'position_ids': NDArray(np.array([list(range(position + 1))], dtype=np.int32))}, state=state)
                logits = output[self.output].numpy().reshape(-1)
                position += 1
        return dict(tokens=tokens, scores=scores, stopped=False)

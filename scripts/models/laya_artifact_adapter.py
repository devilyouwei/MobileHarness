"""Engineering reference adapter for the published macOS wfp16-s512 Laya graph contract."""
import importlib.util
import json

import numpy as np
from coreai.runtime import AIModel, NDArray, SpecializationOptions, ComputeUnitKind


class LayaArtifact:
    @classmethod
    async def load(cls, root):
        from transformers import AutoTokenizer
        self = cls()
        bundle = root / 'macos/wfp16-s512'
        self.metadata = json.loads((bundle / 'metadata.json').read_text())
        self.cfg = self.metadata['decision']
        self.max_len = self.cfg['window']
        self.marker_capacity = self.cfg['head_max_len']
        self.temperature = self.cfg['temperature']
        self.temperature_by_options = self.cfg['temperature_by_options']
        self.tok = AutoTokenizer.from_pretrained(bundle / 'tokenizer')
        spec = importlib.util.spec_from_file_location('published_laya_host', root / '_laya_host.py')
        self.host = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.host)
        self.model = await AIModel.load(bundle / self.metadata['assets']['main'],
                                       SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()).with_debug(enabled=True))
        self.main = self.model.load_function('main')
        self.act = self.model.load_function('act')
        return self

    @staticmethod
    def _internal(question):
        from laya.agent import Agent
        return Agent._to_internal(question)

    async def forward(self, ids, markers, qtype):
        ii = np.zeros((1, self.max_len), dtype=np.int32)
        am = np.zeros_like(ii)
        ii[0, :len(ids)] = ids
        am[0, :len(ids)] = 1
        qt = np.zeros((1, 3), dtype=np.float32)
        qt[0, qtype] = 1
        output = await self.main(dict(input_ids=NDArray(ii), attention_mask=NDArray(am),
                                     qtype_onehot=NDArray(qt)))
        logits = self.host.gather_markers(output['token_logits'].numpy(), markers)
        act = await self.act(dict(pooled_cls=output['pooled_cls'],
                                  feats=NDArray(self.host.act_features(logits))))
        return logits, act['act_logits'].numpy()

    async def predict(self, *, state, questions):
        from laya.common import build_sequence, QTYPES
        answers = {}
        for key, question in questions.items():
            q = self._internal(question)
            ids, markers = build_sequence(self.tok, state, q, self.max_len, self.marker_capacity)
            logits, act = await self.forward(ids, markers, QTYPES[q['t']])
            answers[key] = self.host.decode(logits, act, question, self.cfg)
        return dict(answers=answers)

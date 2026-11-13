"""Minimal GPT-2 forward pass in numpy, for the CKIP gpt2-tiny-chinese model
(https://huggingface.co/ckiplab/gpt2-tiny-chinese, GPL-3.0). Character-level:
each Chinese character is one token of the bert-base-chinese vocabulary.

Used to evaluate language-model reranking before porting it to the input methods.
"""
import json
import math
import struct

import numpy as np

CLS, UNK = 101, 100


def load_safetensors(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        base = 8 + n
        out = {}
        for name, info in header.items():
            if name == "__metadata__" or info["dtype"] != "F32":
                continue
            a, b = info["data_offsets"]
            f.seek(base + a)
            out[name] = np.frombuffer(f.read(b - a), dtype=np.float32).reshape(info["shape"])
    return out


class GPT2:
    def __init__(self, model_dir):
        self.w = load_safetensors(f"{model_dir}/model.safetensors")
        cfg = json.load(open(f"{model_dir}/config.json"))
        self.n_layer, self.n_head = cfg["n_layer"], cfg["n_head"]
        self.eps = cfg["layer_norm_epsilon"]
        self.vocab = {}
        for i, line in enumerate(open(f"{model_dir}/vocab.txt", encoding="utf-8")):
            self.vocab.setdefault(line.rstrip("\n"), i)

    def ids(self, text):
        return [self.vocab.get(c, UNK) for c in text]

    def _ln(self, x, name):
        mu = x.mean(-1, keepdims=True)
        var = ((x - mu) ** 2).mean(-1, keepdims=True)
        return (x - mu) / np.sqrt(var + self.eps) * self.w[name + ".weight"] + self.w[name + ".bias"]

    def hidden(self, ids):
        """Final hidden states [T, d] for token ids."""
        w, T = self.w, len(ids)
        x = w["transformer.wte.weight"][ids] + w["transformer.wpe.weight"][:T]
        mask = np.triu(np.full((T, T), -1e9, dtype=np.float32), 1)
        for l in range(self.n_layer):
            p = f"transformer.h.{l}."
            h = self._ln(x, p + "ln_1")
            qkv = h @ w[p + "attn.c_attn.weight"] + w[p + "attn.c_attn.bias"]
            q, k, v = np.split(qkv, 3, axis=-1)
            d = q.shape[-1] // self.n_head
            q = q.reshape(T, self.n_head, d).transpose(1, 0, 2)
            k = k.reshape(T, self.n_head, d).transpose(1, 0, 2)
            v = v.reshape(T, self.n_head, d).transpose(1, 0, 2)
            att = q @ k.transpose(0, 2, 1) / math.sqrt(d) + mask
            att = np.exp(att - att.max(-1, keepdims=True))
            att /= att.sum(-1, keepdims=True)
            a = (att @ v).transpose(1, 0, 2).reshape(T, -1)
            x = x + a @ w[p + "attn.c_proj.weight"] + w[p + "attn.c_proj.bias"]
            h = self._ln(x, p + "ln_2")
            h = h @ w[p + "mlp.c_fc.weight"] + w[p + "mlp.c_fc.bias"]
            h = 0.5 * h * (1 + np.tanh(math.sqrt(2 / math.pi) * (h + 0.044715 * h ** 3)))   # gelu_new
            x = x + h @ w[p + "mlp.c_proj.weight"] + w[p + "mlp.c_proj.bias"]
        return self._ln(x, "transformer.ln_f")

    def logprob(self, text, context=""):
        """Natural-log probability of `text` given `context` (both strings)."""
        ctx, tgt = self.ids(context), self.ids(text)
        ids = [CLS] + ctx + tgt
        h = self.hidden(ids[:-1])
        logits = h @ self.w["transformer.wte.weight"].T
        logits -= logits.max(-1, keepdims=True)
        lse = np.log(np.exp(logits).sum(-1))
        start = len(ctx)
        return float(sum(logits[start + i, t] - lse[start + i] for i, t in enumerate(tgt)))

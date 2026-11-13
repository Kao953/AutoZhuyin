"""GPT-2 language model for "AI 選字" (numpy). Port of LanguageModel.swift.

Reads the "AZLM" file made by training/lm/export_lm.py (CKIP gpt2-tiny-chinese, GPL-3.0,
float16 weights, expanded to float32 in memory). numpy is optional: when it cannot be
imported, `available()` is False and the input method works without AI.
"""
import json
import math
import struct

try:
    import numpy as np
except Exception:   # ImportError, or a numpy build for another Python / architecture
    np = None

CLS, UNK = 101, 100


def available():
    return np is not None


class GPT2LanguageModel:
    max_tokens = 64

    def __init__(self, model_path, vocab_path):
        if np is None:
            raise RuntimeError("numpy is not available")
        with open(model_path, "rb") as f:
            raw = f.read()
        if raw[:4] != b"AZLM":
            raise ValueError("not an AZLM file")
        n = struct.unpack("<I", raw[4:8])[0]
        header = json.loads(raw[8:8 + n])
        data = np.frombuffer(raw, dtype="<f2", offset=8 + n).astype(np.float32)
        self.n_layer, self.n_head = header["n_layer"], header["n_head"]
        self.d, self.eps = header["n_embd"], header["eps"]
        self.w = {}
        for name, shape, offset in header["tensors"]:
            size = int(np.prod(shape))
            self.w[name] = data[offset:offset + size].reshape(shape)
        self.vocab = {}
        with open(vocab_path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                token = line.rstrip("\n")
                if len(token) == 1:
                    self.vocab.setdefault(token, i)

    def ids(self, text):
        return [self.vocab.get(c, UNK) for c in text]

    def _ln(self, x, name):
        mu = x.mean(-1, keepdims=True)
        var = ((x - mu) ** 2).mean(-1, keepdims=True)
        return (x - mu) / np.sqrt(var + self.eps) * self.w[name + ".weight"] + self.w[name + ".bias"]

    def _hidden(self, ids):
        """ids [B, T] → final hidden states [B, T, d]."""
        w = self.w
        B, T = ids.shape
        x = w["wte.weight"][ids] + w["wpe.weight"][:T]
        mask = np.triu(np.full((T, T), -1e9, dtype=np.float32), 1)
        hd = self.d // self.n_head
        for l in range(self.n_layer):
            p = f"h.{l}."
            h = self._ln(x, p + "ln_1")
            qkv = h @ w[p + "attn.c_attn.weight"] + w[p + "attn.c_attn.bias"]
            q, k, v = np.split(qkv, 3, axis=-1)
            q = q.reshape(B, T, self.n_head, hd).transpose(0, 2, 1, 3)
            k = k.reshape(B, T, self.n_head, hd).transpose(0, 2, 3, 1)
            v = v.reshape(B, T, self.n_head, hd).transpose(0, 2, 1, 3)
            att = q @ k / math.sqrt(hd) + mask
            att = np.exp(att - att.max(-1, keepdims=True))
            att /= att.sum(-1, keepdims=True)
            a = (att @ v).transpose(0, 2, 1, 3).reshape(B, T, self.d)
            x = x + a @ w[p + "attn.c_proj.weight"] + w[p + "attn.c_proj.bias"]
            h = self._ln(x, p + "ln_2")
            h = h @ w[p + "mlp.c_fc.weight"] + w[p + "mlp.c_fc.bias"]
            h = 0.5 * h * (1 + np.tanh(math.sqrt(2 / math.pi) * (h + 0.044715 * h ** 3)))   # gelu_new
            x = x + h @ w[p + "mlp.c_proj.weight"] + w[p + "mlp.c_proj.bias"]
        return self._ln(x, "ln_f")

    def log_probs(self, texts, context=""):
        """Natural-log probabilities of several texts after the same context. Texts of the
        same length are scored together in one batch."""
        out = [0.0] * len(texts)
        by_len = {}
        for i, t in enumerate(texts):
            if t:
                by_len.setdefault(len(t), []).append(i)
        for length, idx in by_len.items():
            ctx = self.ids(context)
            if len(ctx) + length + 1 > self.max_tokens:
                ctx = ctx[max(0, len(ctx) - (self.max_tokens - length - 1)):]
            targets = np.array([self.ids(texts[i]) for i in idx])             # [B, L]
            prefix = np.array([CLS] + ctx)
            inputs = np.concatenate([np.tile(prefix, (len(idx), 1)), targets[:, :-1]], axis=1)
            h = self._hidden(inputs)[:, len(ctx):, :]                          # rows predicting targets
            logits = h @ self.w["wte.weight"].T                                # [B, L, V]
            m = logits.max(-1, keepdims=True)
            lse = np.log(np.exp(logits - m).sum(-1)) + m[..., 0]
            picked = np.take_along_axis(logits, targets[..., None], -1)[..., 0]
            scores = (picked - lse).sum(-1)
            for j, i in enumerate(idx):
                out[i] = float(scores[j])
        return out

    def log_prob(self, text, context=""):
        return self.log_probs([text], context)[0]

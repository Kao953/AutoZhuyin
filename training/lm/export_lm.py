"""Converts the gpt2-tiny-chinese safetensors file to the input method's format.

Format (little-endian):
    "AZLM" magic, uint32 header length, JSON header, then float16 tensors back to back.
    Header: {"n_layer", "n_head", "n_embd", "vocab", "eps", "tensors": [[name, [shape], offset]]}
    (offset in float16 elements from the start of the data). Linear weights keep the
    GPT-2 Conv1D layout [in, out]. The attention mask buffers are dropped.

Usage: export_lm.py <model dir> <out.bin>     (standard library only)
"""
import array
import json
import struct
import sys


def main(src, out):
    cfg = json.load(open(f"{src}/config.json"))
    with open(f"{src}/model.safetensors", "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        base = 8 + n
        names = sorted(k for k, v in header.items() if k != "__metadata__" and v["dtype"] == "F32" and v["shape"])
        tensors, blobs, offset = [], [], 0
        for name in names:
            info = header[name]
            a, b = info["data_offsets"]
            f.seek(base + a)
            floats = array.array("f")
            floats.frombytes(f.read(b - a))
            if sys.byteorder != "little":
                floats.byteswap()
            half = struct.pack(f"<{len(floats)}e", *floats)
            tensors.append([name.replace("transformer.", ""), info["shape"], offset])
            blobs.append(half)
            offset += len(floats)
    meta = json.dumps({"n_layer": cfg["n_layer"], "n_head": cfg["n_head"], "n_embd": cfg["n_embd"],
                       "vocab": cfg["vocab_size"], "eps": cfg["layer_norm_epsilon"],
                       "tensors": tensors}).encode()
    with open(out, "wb") as f:
        f.write(b"AZLM" + struct.pack("<I", len(meta)) + meta)
        for blob in blobs:
            f.write(blob)
    print(f"wrote {out}: {offset} weights")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

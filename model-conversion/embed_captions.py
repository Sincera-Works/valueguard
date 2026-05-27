"""Embed a compiled policy.json's captions into policy.bin.

For each category, takes its positive_captions and negative_captions,
runs them through the SigLIP-2 text tower, averages each side's
embeddings, and packs the resulting vectors into a binary file the
daemon mmaps at startup.

Binary format (all little-endian):
  magic      : 4 bytes  = b"VGP1"
  version    : uint32   = 1
  n_categories: uint32
  embed_dim  : uint32   = 768
  reserved   : uint32   = 0
  for each category:
    id_len   : uint32
    id_utf8  : id_len bytes
    threshold: float32
    action   : uint8     (0=log, 1=blur, 2=block)
    padding  : 3 bytes
    pos_vec  : embed_dim float32 (L2-normalized)
    neg_vec  : embed_dim float32 (L2-normalized)

Run after convert_siglip2.py has produced output/SigLIP2Text.mlpackage.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np
import torch
from transformers import AutoTokenizer

MODEL_ID = "google/siglip2-base-patch16-256"
EMBED_DIM = 768
TEXT_CONTEXT = 64
ACTION_CODES = {"log": 0, "blur": 1, "block": 2}
MAGIC = b"VGP1"


def load_text_encoder():
    """Load the CoreML text tower if available, else fall back to PyTorch.

    The CoreML path matches what the daemon uses at runtime. The PyTorch
    path exists so embed_captions.py works before convert_siglip2.py has
    been run — useful for prototyping.
    """
    mlpkg = Path(__file__).parent / "output" / "SigLIP2Text.mlpackage"
    if mlpkg.exists():
        print(f"Using CoreML text tower: {mlpkg}")
        import coremltools as ct

        model = ct.models.MLModel(str(mlpkg))

        def encode(input_ids: np.ndarray) -> np.ndarray:
            out = model.predict({"input_ids": input_ids.astype(np.int32)})
            return out["embedding"]

        return encode

    print(f"CoreML text tower not found at {mlpkg}")
    print("Falling back to PyTorch transformers (slower, but matches numerically).")
    from transformers import AutoModel

    model = AutoModel.from_pretrained(MODEL_ID).eval()
    text_model = model.text_model

    @torch.no_grad()
    def encode(input_ids: np.ndarray) -> np.ndarray:
        ids = torch.tensor(input_ids, dtype=torch.long)
        out = text_model(input_ids=ids)
        pooled = torch.nn.functional.normalize(out.pooler_output, dim=-1)
        return pooled.numpy()

    return encode


def embed_captions(
    captions: list[str],
    tokenizer,
    encode,
) -> np.ndarray:
    """Embed each caption, average, then L2-normalize the result."""
    toks = tokenizer(
        captions,
        padding="max_length",
        truncation=True,
        max_length=TEXT_CONTEXT,
        return_tensors="np",
    )
    input_ids = toks["input_ids"]

    embeddings = []
    for i in range(len(captions)):
        single = input_ids[i : i + 1]
        emb = encode(single)
        embeddings.append(emb[0])

    stacked = np.stack(embeddings, axis=0)
    mean = stacked.mean(axis=0)
    mean /= np.linalg.norm(mean) + 1e-12
    return mean.astype(np.float32)


def pack_policy(policy: dict, out_path: Path, tokenizer, encode) -> None:
    categories = policy["categories"]
    print(f"Embedding {len(categories)} categor{'y' if len(categories) == 1 else 'ies'}...")

    with open(out_path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<III I", 1, len(categories), EMBED_DIM, 0))

        for cat in categories:
            cat_id = cat["id"].encode("utf-8")
            action = ACTION_CODES[cat["action"]]
            threshold = float(cat["threshold"])

            print(f"  {cat['id']}: "
                  f"{len(cat['positive_captions'])} pos / "
                  f"{len(cat['negative_captions'])} neg captions")

            pos_vec = embed_captions(cat["positive_captions"], tokenizer, encode)
            neg_vec = embed_captions(cat["negative_captions"], tokenizer, encode)

            assert pos_vec.shape == (EMBED_DIM,), pos_vec.shape
            assert neg_vec.shape == (EMBED_DIM,), neg_vec.shape

            f.write(struct.pack("<I", len(cat_id)))
            f.write(cat_id)
            f.write(struct.pack("<fB3x", threshold, action))
            f.write(pos_vec.tobytes())
            f.write(neg_vec.tobytes())

    print(f"Wrote {out_path} ({out_path.stat().st_size} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("policy_json", type=Path, help="path to compiled policy.json")
    parser.add_argument("--out", type=Path, default=None, help="output policy.bin path")
    args = parser.parse_args()

    if not args.policy_json.exists():
        print(f"error: {args.policy_json} not found", file=sys.stderr)
        return 1

    out_path = args.out
    if out_path is None:
        if args.policy_json.name.endswith(".policy.json"):
            out_path = args.policy_json.with_name(
                args.policy_json.name.replace(".policy.json", ".policy.bin")
            )
        else:
            out_path = args.policy_json.with_suffix(".policy.bin")

    policy = json.loads(args.policy_json.read_text())

    print(f"Loading tokenizer for {MODEL_ID}")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    encode = load_text_encoder()

    pack_policy(policy, out_path, tokenizer, encode)
    print("")
    print("Next step:")
    print(f"  cd ../daemon && swift run valueguard --policy {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

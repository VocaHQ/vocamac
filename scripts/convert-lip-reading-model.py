# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch==2.15.0",
#   "coremltools==9.0",
#   "numpy==2.5.4",
#   "six==1.17.0",
# ]
# ///
"""Build Silent Mode's English lip-reading model.

Converts Auto-AVSR's visual speech recognition checkpoint LRS3_V_WER19.1 to
Core ML (the encoder with its CTC head, and the attention decoder VocaMac's
beam search uses), for 122 input lengths from 8 to 750 frames (0.3 to 30 s at
25 fps), and writes them with the token list where VocaMac looks:

    ~/Library/Application Support/VocaMac/models/lip-reading/
        LipReader.mlpackage     encoder + CTC head
        LipDecoder.mlpackage    attention decoder
        tokens.json

The weights are not VocaMac's to redistribute: they carry the terms of the
data they were trained on (LRS3 from TED, LRS2 and LRW from the BBC), which
allow research and non-commercial use only. This script downloads them for
your own use on your Mac.

    uv run scripts/convert-lip-reading-model.py            # FP32, ~740 MB, best accuracy
    uv run scripts/convert-lip-reading-model.py --fp16     # ~370 MB, about 2 points more WER
    uv run scripts/convert-lip-reading-model.py --out DIR  # somewhere else (then Import in Settings)

Takes about 10 minutes and 3 GB of downloads (PyTorch and the 958 MB
checkpoint). Measured on 60 LRS3 test clips: 26.3% WER with VocaMac's beam
search (beam 10, CTC weight 0.1), against 32.5% decoding greedily and 25.5%
for Auto-AVSR's own beam search in PyTorch.
"""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

# Chaplin (MIT) carries Auto-AVSR's model code (Apache-2.0) and the token list.
CHAPLIN_URL = "https://github.com/amanvirparhar/chaplin.git"
CHAPLIN_COMMIT = "7aee1f8fca776ce4f63690063310b53573b7d804"
WEIGHTS_REPO = "https://huggingface.co/Amanvir/LRS3_V_WER19.1/resolve/c0b413f56b164565865a63f00774ee55a9738cc5"
FILES = {
    "model.pth": "e740cef369abeabd0ba2c18e37a0661342e1d94d432d6caa77755a11821d8fe3",
    "model.json": "e062e8c58579f54cb51087e639e674781189809905db4162efe0fe1325356d4f",
}
TOKENS_SHA256 = "29001d967ad290e28f6f1d7d47e07e314354bf67d3b1f494e936fa2fed9a9122"
DEFAULT_OUT = Path.home() / "Library/Application Support/VocaMac/models/lip-reading"
# Must match LipReadingWindow.lengths: fine steps for short stretches,
# coarser for long ones; Core ML allows 128 enumerated shapes at most.
LENGTHS = list(range(8, 60, 2)) + list(range(60, 200, 4)) + list(range(200, 400, 8)) + list(range(400, 751, 10))
BEAM = 10        # LipBeamSearch.Configuration.beamWidth
MAX_TOKENS = 64  # LipBeamSearch.Configuration.maximumLength


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(name: str, folder: Path) -> Path:
    path = folder / name
    if path.exists() and sha256(path) == FILES[name]:
        return path
    print(f"Downloading {name}…", flush=True)
    urllib.request.urlretrieve(f"{WEIGHTS_REPO}/{name}", path)
    if sha256(path) != FILES[name]:
        sys.exit(f"{name} doesn't match its expected SHA-256; not converting it.")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="where to write the model")
    parser.add_argument("--fp16", action="store_true", help="half the size, slightly less accurate")
    parser.add_argument("--work", type=Path, help="keep downloads here between runs")
    args = parser.parse_args()

    work = args.work or Path(tempfile.mkdtemp(prefix="vocamac-lipreading-"))
    work.mkdir(parents=True, exist_ok=True)
    source = work / "chaplin"
    if not (source / ".git").exists():
        subprocess.run(["git", "clone", "--quiet", CHAPLIN_URL, str(source)], check=True)
    subprocess.run(["git", "-C", str(source), "checkout", "--quiet", CHAPLIN_COMMIT], check=True)
    units_path = source / "pipelines/tokens/unigram5000_units.txt"
    if sha256(units_path) != TOKENS_SHA256:
        sys.exit("The token list doesn't match its expected SHA-256.")
    weights = {name: fetch(name, work) for name in FILES}

    import numpy as np
    import torch
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

    sys.path.insert(0, str(source))
    from espnet.nets.pytorch_backend.e2e_asr_transformer import E2E

    @register_torch_op
    def view_as(context, node):
        x, other = _get_inputs(context, node, expected=2)
        context.add(mb.reshape(x=x, shape=mb.shape(x=other), name=node.name))

    conf = json.loads(weights["model.json"].read_text())
    train_args = argparse.Namespace(**(conf if isinstance(conf, dict) else conf[2]))
    units = units_path.read_text().splitlines()
    tokens = ["<blank>"] + [unit.split()[0] for unit in units] + ["<eos>"]
    e2e = E2E(len(tokens), train_args)
    e2e.load_state_dict(torch.load(weights["model.pth"], map_location="cpu"))
    e2e.eval()

    class LipReader(torch.nn.Module):
        """Mouth crops [1, 1, T, 88, 88] → CTC log-probabilities [1, T, vocabulary]."""

        def __init__(self, model):
            super().__init__()
            self.encoder = model.encoder
            self.ctc_lo = model.ctc.ctc_lo

        def forward(self, video):
            encoded, _ = self.encoder(video, None)
            return torch.log_softmax(self.ctc_lo(encoded), dim=-1), encoded

    class LipDecoder(torch.nn.Module):
        """BEAM prefixes [BEAM, MAX_TOKENS] (padded), encoder output [1, T, 768] and the
        position of the prefixes' last token → next-token log-probabilities [BEAM, vocabulary].
        The causal mask makes the padding after `position` irrelevant."""

        def __init__(self, model):
            super().__init__()
            self.decoder = model.decoder
            self.register_buffer("mask", torch.tril(torch.ones(MAX_TOKENS, MAX_TOKENS, dtype=torch.bool)).unsqueeze(0))

        def forward(self, tokens, memory, position):
            x = self.decoder.embed(tokens.long())
            memory = memory.expand(BEAM, -1, -1)
            for layer in self.decoder.decoders:
                x, _, _, _ = layer(x, self.mask, memory, None)
            last = torch.index_select(x, 1, position.long()).squeeze(1)
            return torch.log_softmax(self.decoder.output_layer(self.decoder.after_norm(last)), dim=-1)

    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32
    terms = "Weights: research and non-commercial use only (LRS3, LRS2, LRW terms). Code: Apache-2.0 (mpc001/auto_avsr)."
    model = LipReader(e2e).eval()
    decoder = LipDecoder(e2e).eval()
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.randn(1, 1, 80, 88, 88), check_trace=False)
        traced_decoder = torch.jit.trace(decoder, (
            torch.full((BEAM, MAX_TOKENS), len(tokens) - 1, dtype=torch.int32), torch.randn(1, 80, 768),
            torch.tensor([0], dtype=torch.int32),
        ), check_trace=False)

    print("Converting to Core ML…", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="video", shape=ct.EnumeratedShapes(
            shapes=[(1, 1, length, 88, 88) for length in LENGTHS], default=(1, 1, 80, 88, 88)), dtype=np.float32)],
        outputs=[ct.TensorType(name="log_probs", dtype=np.float32), ct.TensorType(name="encoder_out", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14, compute_precision=precision, convert_to="mlprogram",
    )
    mlmodel.short_description = "Auto-AVSR LRS3_V_WER19.1 visual-only encoder and CTC head: English lip reading."
    mlmodel.license = terms
    mldecoder = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="tokens", shape=(BEAM, MAX_TOKENS), dtype=np.int32),
            ct.TensorType(name="memory", shape=ct.EnumeratedShapes(
                shapes=[(1, length, 768) for length in LENGTHS], default=(1, 80, 768)), dtype=np.float32),
            ct.TensorType(name="position", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="log_probs", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14, compute_precision=precision, convert_to="mlprogram",
    )
    mldecoder.short_description = "Auto-AVSR LRS3_V_WER19.1 attention decoder, one step for a batch of prefixes."
    mldecoder.license = terms

    # Check both against PyTorch before installing anything.
    sample = np.random.default_rng(0).standard_normal((1, 1, 80, 88, 88)).astype(np.float32)
    with torch.no_grad():
        reference, encoded = model(torch.from_numpy(sample))
    produced = mlmodel.predict({"video": sample})
    agreement = float((reference.numpy().argmax(-1) == produced["log_probs"].argmax(-1)).mean())
    prefixes = np.full((BEAM, MAX_TOKENS), len(tokens) - 1, dtype=np.int32)
    prefixes[:, 1] = np.arange(BEAM) + 7
    with torch.no_grad():
        decoder_reference = decoder(torch.from_numpy(prefixes), encoded, torch.tensor([1], dtype=torch.int32)).numpy()
    decoder_produced = mldecoder.predict({"tokens": prefixes, "memory": produced["encoder_out"], "position": np.array([1], dtype=np.int32)})["log_probs"]
    decoder_agreement = float((decoder_reference.argmax(-1) == decoder_produced.argmax(-1)).mean())
    print(f"Agreement with PyTorch on a test input: encoder {agreement:.3f}, decoder {decoder_agreement:.3f}")
    if agreement < 0.95 or decoder_agreement < 0.95:
        sys.exit("The converted model disagrees with PyTorch; not installing it.")

    args.out.mkdir(parents=True, exist_ok=True)
    for stale in ("LipReader.mlpackage", "LipReader.mlmodelc", "LipDecoder.mlpackage", "LipDecoder.mlmodelc"):
        target = args.out / stale
        if target.exists():
            subprocess.run(["rm", "-rf", str(target)], check=True)
    mlmodel.save(str(args.out / "LipReader.mlpackage"))
    mldecoder.save(str(args.out / "LipDecoder.mlpackage"))
    (args.out / "tokens.json").write_text(json.dumps(tokens, ensure_ascii=False))
    (args.out / "NOTICE.txt").write_text(
        "Auto-AVSR visual speech recognition model LRS3_V_WER19.1 (Ma et al., ICASSP 2023,\n"
        "https://github.com/mpc001/auto_avsr), converted to Core ML for VocaMac's Silent Mode.\n"
        "The weights carry the terms of their training data and are for research and\n"
        "non-commercial use only. Do not redistribute them.\n"
    )
    print(f"Installed in {args.out}. Restart VocaMac's Silent Mode recording to use it.")


if __name__ == "__main__":
    main()

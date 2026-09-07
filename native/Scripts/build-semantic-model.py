#!/usr/bin/env python3
"""Reproduce the bundled, offline MiniLM Core ML model on macOS.

uv venv --python 3.12 /tmp/ccbuddy-coreml-conversion
uv pip install --python /tmp/ccbuddy-coreml-conversion/bin/python \
    torch==2.7.0 transformers==4.51.3 coremltools==8.3.0 'numpy<2' safetensors
/tmp/ccbuddy-coreml-conversion/bin/python native/Scripts/build-semantic-model.py

Downloads only the pinned upstream safetensors checkpoint (never pickle/code).
Converts linear projections to equivalent 1x1 convolutions and keeps attention
rank four so Core ML can schedule transformer work on Apple Neural Engine.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
MODEL = "sentence-transformers/all-MiniLM-L6-v2"
WEIGHT_SHA256 = "53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db"
SOURCE_SHA256 = {
    "model.safetensors": WEIGHT_SHA256,
    "config.json": "953f9c0d463486b10a6871cc2fd59f223b2c70184f49815e7efbcab5d8908b41",
    "vocab.txt": "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
    "tokenizer_config.json": "acb92769e8195aabd29b7b2137a9e6d6e25c476a4f15aa4355c233426c61576b",
    "special_tokens_map.json": "303df45a03609e4ead04bc3dc1536d0ab19b5358db685b6f3da123d05ec200e3",
    "README.md": "dcd602d2fd35c203a247304a06fec6654a12f7941b739f9221a064fe8dc3b7f0",
}
LICENSE_SHA256 = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
TOKEN_COUNT = 128


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path("/tmp/ccbuddy-minilm-source"))
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1] / "Resources" / "SemanticSearch")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    for name, expected_digest in SOURCE_SHA256.items():
        destination = args.cache / name
        if not destination.exists():
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(destination),
                            f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}"], check=True)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        if digest != expected_digest:
            raise SystemExit(f"Upstream {name} checksum mismatch: {digest}")
    license_path = args.output / "MiniLM-LICENSE.txt"
    if not license_path.exists():
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(license_path),
                        "https://www.apache.org/licenses/LICENSE-2.0.txt"], check=True)
    if hashlib.sha256(license_path.read_bytes()).hexdigest() != LICENSE_SHA256:
        raise SystemExit("Apache license checksum mismatch")

    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoModel, AutoTokenizer

    torch.set_num_threads(4)
    reference = AutoModel.from_pretrained(str(args.cache), local_files_only=True,
                                          use_safetensors=True, attn_implementation="eager").eval()
    tokenizer = AutoTokenizer.from_pretrained(str(args.cache), local_files_only=True)

    def projection(linear):
        conv = torch.nn.Conv2d(linear.in_features, linear.out_features, 1)
        conv.weight = torch.nn.Parameter(linear.weight.detach().reshape(conv.weight.shape))
        conv.bias = torch.nn.Parameter(linear.bias.detach())
        return conv

    class ChannelNorm(torch.nn.Module):
        def __init__(self, norm):
            super().__init__()
            self.weight = torch.nn.Parameter(norm.weight.detach().reshape(1, -1, 1, 1))
            self.bias = torch.nn.Parameter(norm.bias.detach().reshape(1, -1, 1, 1))
            self.eps = norm.eps

        def forward(self, value):
            centered = value - value.mean(dim=1, keepdim=True)
            variance = (centered * centered).mean(dim=1, keepdim=True)
            return centered * torch.rsqrt(variance + self.eps) * self.weight + self.bias

    class Block(torch.nn.Module):
        def __init__(self, layer):
            super().__init__()
            self.query = projection(layer.attention.self.query)
            self.key = projection(layer.attention.self.key)
            self.value = projection(layer.attention.self.value)
            self.attention_output = projection(layer.attention.output.dense)
            self.attention_norm = ChannelNorm(layer.attention.output.LayerNorm)
            self.intermediate = projection(layer.intermediate.dense)
            self.output = projection(layer.output.dense)
            self.output_norm = ChannelNorm(layer.output.LayerNorm)

        def forward(self, hidden, mask):
            query = self.query(hidden).reshape(1, 12, 32, TOKEN_COUNT).transpose(2, 3)
            key = self.key(hidden).reshape(1, 12, 32, TOKEN_COUNT)
            value = self.value(hidden).reshape(1, 12, 32, TOKEN_COUNT).transpose(2, 3)
            scores = torch.matmul(query, key) * (32 ** -0.5) + mask
            context = torch.matmul(torch.softmax(scores, dim=-1), value)
            context = context.transpose(2, 3).reshape(1, 384, 1, TOKEN_COUNT)
            attended = self.attention_norm(hidden + self.attention_output(context))
            return self.output_norm(attended + self.output(torch.nn.functional.gelu(self.intermediate(attended))))

    class EmbeddingModel(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.words = reference.embeddings.word_embeddings
            self.register_buffer("position_and_type", reference.embeddings.position_embeddings.weight[:TOKEN_COUNT]
                                 + reference.embeddings.token_type_embeddings.weight[0])
            self.norm = ChannelNorm(reference.embeddings.LayerNorm)
            self.layers = torch.nn.ModuleList([Block(layer) for layer in reference.encoder.layer])

        def forward(self, input_ids, attention_mask):
            hidden = (self.words(input_ids) + self.position_and_type).transpose(1, 2).unsqueeze(2)
            hidden = self.norm(hidden)
            pooling_mask = attention_mask.reshape(1, 1, 1, TOKEN_COUNT).float()
            mask = (1.0 - pooling_mask) * -10000.0
            for layer in self.layers:
                hidden = layer(hidden, mask)
            return ((hidden * pooling_mask).sum(dim=3) / pooling_mask.sum(dim=3).clamp(min=1)).reshape(1, 384)

    network = EmbeddingModel().eval()
    examples = ["Fix authentication errors when the API key expires.",
                "Renew credentials to restore access to the service.",
                "Arrange the sidebar icons and change the background color.",
                "Investigate slow database queries and reduce response latency."]
    inputs = tokenizer(examples, return_tensors="pt", padding="max_length", truncation=True,
                       max_length=TOKEN_COUNT)
    expected = []
    with torch.no_grad():
        for index in range(len(examples)):
            ids, mask = inputs.input_ids[index:index + 1], inputs.attention_mask[index:index + 1]
            original = reference(input_ids=ids, attention_mask=mask).last_hidden_state
            original = (original * mask.unsqueeze(-1)).sum(dim=1) / mask.sum(dim=1, keepdim=True)
            rewritten = network(ids, mask)
            torch.testing.assert_close(rewritten, original, atol=2e-5, rtol=2e-4)
            expected.append(original.numpy())
        traced = torch.jit.trace(network, (inputs.input_ids[:1], inputs.attention_mask[:1]))
    model = ct.convert(traced,
                       inputs=[ct.TensorType(name="input_ids", shape=(1, TOKEN_COUNT), dtype=np.int32),
                               ct.TensorType(name="attention_mask", shape=(1, TOKEN_COUNT), dtype=np.int32)],
                       outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                       minimum_deployment_target=ct.target.macOS13,
                       compute_precision=ct.precision.FLOAT16,
                       compute_units=ct.ComputeUnit.CPU_AND_NE)
    model = ct.optimize.coreml.linear_quantize_weights(
        model, config=ct.optimize.coreml.OptimizationConfig(
            global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
    model.short_description = "Offline English/code sentence embeddings. MiniLM-L6-v2, 384 dimensions, 128 tokens."
    model.author = "Sentence Transformers; Core ML conversion by CC Buddy contributors"
    model.license = "Apache-2.0"
    model.version = "1"
    model.user_defined_metadata["source"] = f"https://huggingface.co/{MODEL}/tree/{REVISION}"
    model.user_defined_metadata["source_sha256"] = WEIGHT_SHA256
    model.user_defined_metadata["language"] = "en"
    model.user_defined_metadata["compute_policy"] = "CPU and Neural Engine; scheduling is decided by Core ML"
    destination = args.output / "MiniLMSemantic.mlpackage"
    model.save(str(destination))
    shutil.copyfile(args.cache / "vocab.txt", args.output / "minilm-vocab.txt")
    shutil.copyfile(args.cache / "README.md", args.output / "MODEL-CARD.md")

    similarities = []
    for index, example in enumerate(examples):
        result = model.predict({"input_ids": inputs.input_ids[index:index + 1].numpy().astype(np.int32),
                                "attention_mask": inputs.attention_mask[index:index + 1].numpy().astype(np.int32)})["embedding"]
        left, right = result.flatten(), expected[index].flatten()
        cosine = float(np.dot(left, right) / (np.linalg.norm(left) * np.linalg.norm(right)))
        assert cosine > 0.995, f"Quantization parity failed: {example}: {cosine}"
        similarities.append(cosine)
    manifest = {"model": MODEL, "revision": REVISION, "license": "Apache-2.0", "language": "en",
                "source_weight_sha256": WEIGHT_SHA256, "max_tokens": TOKEN_COUNT, "dimensions": 384,
                "coremltools": ct.__version__, "torch": torch.__version__,
                "conversion": "Static 4D attention, 1x1 convolution projections, float16 compute, int8 weights",
                "reference_cosine_similarities": similarities,
                "sha256": {str(file.relative_to(args.output)): hashlib.sha256(file.read_bytes()).hexdigest()
                           for file in sorted(args.output.rglob("*")) if file.is_file() and file.name != "manifest.json"}}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

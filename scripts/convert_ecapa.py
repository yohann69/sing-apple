import torch, math, numpy as np, coremltools as ct
from speechbrain.inference.speaker import EncoderClassifier
enc = EncoderClassifier.from_hparams(source="speechbrain/spkrec-ecapa-voxceleb", savedir="ecapa_src", run_opts={"device":"cpu"})
fb = enc.mods.compute_features.compute_fbanks.eval()
emb = enc.mods.embedding_model.eval()
N = 400
win = torch.hamming_window(N)
n = torch.arange(N).float(); k = torch.arange(N // 2 + 1).float()
ang = 2 * math.pi * k[:, None] * n[None, :] / N
basis = torch.cat([torch.cos(ang) * win, -torch.sin(ang) * win], 0)[:, None, :]
class Front(torch.nn.Module):
    def __init__(s):
        super().__init__(); s.register_buffer("basis", basis); s.fb = fb; s.emb = emb
    def forward(s, wav):
        x = torch.nn.functional.pad(wav[:, None, :], (200, 200))
        y = torch.nn.functional.conv1d(x, s.basis, stride=160)
        re, im = y[:, :201], y[:, 201:]
        p = (re * re + im * im).transpose(1, 2)
        f = s.fb(p)
        f = f - f.mean(dim=1, keepdim=True)
        return s.emb(f).squeeze(1)
m = Front().eval()
torch.manual_seed(0)
wav = torch.randn(1, 48000) * 0.1
with torch.no_grad():
    ref = enc.encode_batch(wav).squeeze(1)
    out = m(wav)
print("cos vs speechbrain", float(torch.nn.functional.cosine_similarity(ref, out)))
tr = torch.jit.trace(m, wav)
ml = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, ct.RangeDim(8000, 480000, default=48000)))], outputs=[ct.TensorType(name="embedding")],
                minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram")
ml.short_description = "ECAPA-TDNN speaker embedding (SpeechBrain, Apache-2.0) with its fbank front end. Input: 16 kHz mono audio (1, samples). Output: (1, 192)."
ml.save("ecapa.mlpackage")
p = ml.predict({"audio": wav.numpy()})["embedding"]
print("cos coreml", float(np.dot(p.ravel(), out.numpy().ravel()) / np.linalg.norm(p) / np.linalg.norm(out.numpy())))

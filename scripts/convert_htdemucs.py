import math, sys
import torch, torch.nn as nn
import coremltools as ct
import numpy as np
from demucs.pretrained import get_model

name = sys.argv[1] if len(sys.argv) > 1 else "htdemucs"
bag = get_model(name)
m = bag.models[0].eval()
print(type(m).__name__, m.sources, m.samplerate, float(m.segment), m.nfft, m.hop_length, m.cac)
L = int(float(m.segment) * m.samplerate)
le = int(math.ceil(L / m.hop_length))
F_ = m.nfft // 2

class Core(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, mix, mag):
        m = self.m
        x = mag
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        S = len(m.sources)
        x = x.view(B, S * 4, Fq, T)
        x = x * std + mean
        xt = xt.view(B, S * 2, -1)
        xt = xt * stdt + meant
        return x, xt

core = Core(m).eval()
mix = torch.randn(1, 2, L)
z = m._spec(mix)
mag = m._magnitude(z)
print("mag", mag.shape, "L", L)
with torch.no_grad():
    ref = m(mix)
    fx, tx = core(mix, mag)
    S = len(m.sources)
    zout = m._mask(z, fx.view(1, S, 4, F_, le))
    full = m._ispec(zout, L) + tx.view(1, S, 2, L)
    print("max diff vs reference", (full - ref).abs().max().item())
    import demucs.transformer as T
    cache = {}
    o2d, o1d = T.create_2d_sin_embedding, T.create_sin_embedding
    def c2d(*a, **k):
        key = ("2d",) + tuple(a[:3])
        if key not in cache: cache[key] = o2d(*a, **k).detach().clone()
        return cache[key]
    def c1d(*a, **k):
        key = ("1d",) + tuple(a[:2]) + (k.get("shift", 0),)
        if key not in cache: cache[key] = o1d(*a, **k).detach().clone()
        return cache[key]
    T.create_2d_sin_embedding, T.create_sin_embedding = c2d, c1d
    traced = torch.export.export(core, (mix, mag), strict=False).run_decompositions({})
mlm = ct.convert(
    traced,
    inputs=[ct.TensorType(name="mix", shape=mix.shape), ct.TensorType(name="mag", shape=mag.shape)],
    outputs=[ct.TensorType(name="freq"), ct.TensorType(name="time")],
    compute_precision=ct.precision.FLOAT16 if "--fp16" in sys.argv else ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS15,
    convert_to="mlprogram",
)
mlm.author = "Meta (Demucs, MIT), converted for Sing!"
mlm.short_description = f"{name} core without STFT. Inputs: mix (1,2,{L}) and CaC spectrogram (1,4,{F_},{le}); outputs freq spectrogram per source (CaC) and time-branch waveform per source. Sources: {m.sources}"
out = f"{name}{'_fp16' if '--fp16' in sys.argv else ''}.mlpackage"
mlm.save(out)
p = mlm.predict({"mix": mix.numpy(), "mag": mag.numpy()})
print("coreml freq diff", np.abs(p["freq"] - fx.numpy()).max(), "time diff", np.abs(p["time"] - tx.numpy()).max())

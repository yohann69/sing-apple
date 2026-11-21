import sys, torch, torchcrepe, numpy as np, coremltools as ct
cap = sys.argv[1] if len(sys.argv) > 1 else "full"
torchcrepe.load.model("cpu", cap)
m = torchcrepe.infer.model.eval()
B = 256
class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, frames):
        # frames: (B, 1024) already normalised (zero mean, unit std) as torchcrepe does
        return self.m(frames, embed=False)
w = Wrap(m).eval()
x = torch.randn(B, 1024)
with torch.no_grad():
    ref = w(x)
    tr = torch.jit.trace(w, x)
ml = ct.convert(tr, inputs=[ct.TensorType(name="frames", shape=(B, 1024))], outputs=[ct.TensorType(name="salience")],
                minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16)
ml.short_description = f"CREPE {cap}: (256,1024) 16 kHz frames, normalised -> (256,360) pitch salience, 20 cents per bin from C1"
ml.save(f"crepe_{cap}.mlpackage")
p = ml.predict({"frames": x.numpy()})["salience"]
print("max diff", np.abs(p - ref.numpy()).max(), "argmax agree", (p.argmax(1) == ref.numpy().argmax(1)).mean())

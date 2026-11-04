"""Render the README figure from the archived measurement records."""

import json
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parents[2]
data = json.loads((root / "Benchmarks/results/scglayer-v6/summary.json").read_text())
rows = {r["backend"]: r for r in data["rows"] if r["scene"] == "shape"}
values = [rows[backend]["displaySwapsPerSecond"]
          for backend in ["layers", "drawRect", "SCGLayer"]]
ratio = values[2] / values[1]
plt.rcParams.update({"font.family": "sans-serif", "font.sans-serif": ["DejaVu Sans"],
                     "text.color": "#eaf4ff", "axes.labelcolor": "#a8bed4",
                     "xtick.color": "#a8bed4", "ytick.color": "#eaf4ff"})
fig, ax = plt.subplots(figsize=(12, 6.5), dpi=160, facecolor="#081827")
ax.set_facecolor("#081827")
fig.subplots_adjust(left=.30, right=.94, top=.61, bottom=.25)
fig.text(.06, .92, "SCGLayer · MEASURED ON iPHONE", fontsize=12, color="#65d9ef", weight="bold")
fig.text(.06, .81, f"{ratio:.1f}× display cadence vs drawRect", fontsize=30, weight="bold")
fig.text(.06, .72, "Same CoreGraphics scene. Different CGContext backends.", fontsize=14, color="#a8bed4")
fig.text(.06, .66, "1,000 complex paths per update; CAShapeLayer reference fully rebuilt.", fontsize=12, color="#a8bed4")
ax.barh([2, 1, 0], values, height=.52, color=["#687c92", "#63a8ef", "#39d8c2"])
ax.set_yticks([2, 1, 0], ["CAShapeLayer tree", "drawRect · CoreGraphics", "SCGLayer · CoreGraphics"])
ax.set_xlim(0, 68)
ax.set_xticks([0, 15, 30, 45, 60])
ax.set_xlabel("App-associated display swaps / second", labelpad=10)
ax.tick_params(axis="both", length=0, labelsize=12)
for spine in ax.spines.values():
    spine.set_visible(False)
for y, value in zip([2, 1, 0], values):
    ax.text(value + .8, y, f"{value:.1f}", va="center", fontsize=17, weight="bold")
fig.text(.06, .10, "iPhone 12 · A14 · iOS 27.2 beta · 60 Hz requested · 8 s steady trace", fontsize=11, color="#a8bed4")
fig.text(.06, .05, "Standalone library demo · fixture 6 · presentation events, not callback FPS · workload-specific result", fontsize=10, color="#a8bed4")
destination = root / "Docs/assets/presentation-cadence.png"
fig.savefig(destination, facecolor=fig.get_facecolor())
plt.close(fig)
print(destination)

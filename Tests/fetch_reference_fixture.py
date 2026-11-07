from pathlib import Path
import urllib.request

# Public Apple reference stream; no Netflix login or media is used.
BASE = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/Job932393e2-1e4f-4fdb-ab59-0d201f752656-107660254-Transcode_audio_full_en_atmos_0_1-en_audio/'
folder = Path(__file__).resolve().parent / "fixtures"
folder.mkdir(exist_ok=True)
for remote, local in [("fileSequence0.mp4", "apple-atmos-init.mp4"), ("fileSequence1.m4s", "apple-first-fragment.m4s")]:
    with urllib.request.urlopen(BASE + remote, timeout=30) as response:
        data = response.read(2_000_001)
    if len(data) > 2_000_000: raise RuntimeError("Reference fixture exceeded size limit")
    (folder / local).write_bytes(data)

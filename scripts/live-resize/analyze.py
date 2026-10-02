#!/usr/bin/env python3
"""Summarize a live-resize run (run.sh): what the screen showed (rec.txt) against what fizzy drew
(app.log, FIZZY_LIVE_RESIZE_TRACE). usage: analyze.py <run-dir> [-v]

A captured frame is *stretched* when the content in it was drawn for a size other than the one
the window shows it at (barcode width vs. edge bars). Only frames captured while the window was
changing size (between the first and last resize step) count.
"""
import re, sys, statistics as st

run = sys.argv[1]
verbose = '-v' in sys.argv
app = open(f"{run}/app.log").read().splitlines()
rec = open(f"{run}/rec.txt").read().splitlines()

steps = [float(l.split()[1]) for l in app if l.startswith('[lr]') and ' step ' in l]
frames = {}
for l in app:
    m = re.match(r'\[lr\] (\S+) frame (\d+) src=(\w+) since=(\S+)ms took=(\S+)ms .* swap=(\d+)x(\d+)', l)
    if m:
        frames[int(m.group(2))] = dict(t=float(m.group(1)), src=m.group(3), took=float(m.group(5)), w=int(m.group(6)), h=int(m.group(7)))
if not steps:
    print("no steps"); sys.exit()
t0, t1 = steps[0], steps[-1]

cap = []
base = None  # the measurement's own offset, from the idle frames before the drag
for l in rec:
    m = re.match(r'(\S+) (\d+) drawn=(\d+) (\d+)x(\d+) pitch=\S+ shown=(-?\d+)x(-?\d+)', l)
    if not m:
        continue
    t = float(m.group(1))
    if t < t0 - 0.05 and base is None:
        base = (int(m.group(6)) - int(m.group(4)), int(m.group(7)) - int(m.group(5)))
    if t < t0 or t > t1 + 0.02:
        continue
    cap.append(dict(t=t, n=int(m.group(3)), dw=int(m.group(4)), dh=int(m.group(5)), sw=int(m.group(6)), sh=int(m.group(7))))

undecoded = sum(1 for l in rec if 'drawn=?' in l)
srcs = {}
for f in frames.values():
    srcs[f['src']] = srcs.get(f['src'], 0) + 1
took = [f['took'] for f in frames.values()]
print(f"steps {len(steps)} over {t1 - t0:.2f}s ({len(steps) / (t1 - t0):.0f}/s); frames {len(frames)} {srcs}; "
      f"frame took median {st.median(took) if took else 0:.2f}ms max {max(took) if took else 0:.2f}ms")
if not cap:
    print("no decoded captures in the drag", f"(undecoded {undecoded})"); sys.exit()

bx, by = base or (0, 0)
print(f"measurement offset (idle): {bx},{by}")
def off(c):
    return max(abs(c['sw'] - c['dw'] - bx), abs(c['sh'] - c['dh'] - by))

bad = [c for c in cap if off(c) > 1]
distinct = len(set(c['n'] for c in cap))
gaps = [b['t'] - a['t'] for a, b in zip(cap, cap[1:])]
print(f"captured {len(cap)} screen updates during the drag ({len(cap) / (t1 - t0):.0f}/s), {distinct} distinct app frames, "
      f"undecoded {undecoded}")
print(f"stretched (drawn size != shown size, >1px): {len(bad)} / {len(cap)} = {100 * len(bad) / len(cap):.0f}%"
      + (f"; mismatch px median {st.median([off(c) for c in bad]):.0f} max {max(off(c) for c in bad)}" if bad else ""))
if gaps:
    print(f"screen update interval ms: median {1000 * st.median(gaps):.1f} p90 {1000 * sorted(gaps)[int(.9 * len(gaps))]:.1f} max {1000 * max(gaps):.1f}")
if verbose:
    for c in cap:
        f = frames.get(c['n'], {})
        print(f"{c['t']:.4f} frame {c['n']:5d} {f.get('src', '?'):5s} drawn {c['dw']}x{c['dh']} shown {c['sw']}x{c['sh']} {'STRETCHED' if off(c) > 1 else ''}")

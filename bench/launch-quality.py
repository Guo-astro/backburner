#!/usr/bin/env python3
"""launch-quality.py - does the iPhone change the model's output? Compares the greedy decode runs that bench/launch-bench.py
recorded (bench/results/results.jsonl) between two configs at each depth:
  - identical: how many of the generated tokens match before the first difference (greedy, same prompt);
  - top-1 agreement and the largest probability gap of the top token over the positions both runs share (up to 64);
  - first token: the top-10 log-probs right after the prompt, which depend only on how the prompt was read.

  bench/launch-quality.py [--a fork-mac] [--b fork-phone]
"""
import argparse, json, math, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument('--a', default='fork-mac')
ap.add_argument('--b', default='fork-phone')
ap.add_argument('--file', default=os.path.join(ROOT, 'bench-out', 'launch', 'results.jsonl'))
a = ap.parse_args()

runs = {}
for line in open(a.file):
    r = json.loads(line)
    if r.get('kind') == 'decode' and r.get('tokens') and r.get('note') != 'smoke':
        runs[(r['config'], r['depth'])] = r   # the latest run of each config and depth

print(f'{a.a} vs {a.b} (greedy, same prompt)')
print(f'{"depth":>7} {"identical":>12} {"top-1 same":>11} {"max |dp| top-1":>15} {"first-token top-10 overlap":>27}')
for d in sorted({k[1] for k in runs}):
    ra, rb = runs.get((a.a, d)), runs.get((a.b, d))
    if not ra or not rb:
        continue
    ta, tb = ra['tokens'], rb['tokens']
    same = next((i for i, (x, y) in enumerate(zip(ta, tb)) if x != y), min(len(ta), len(tb)))
    pa, pb = ra.get('probs') or [], rb.get('probs') or []
    agree = n = 0
    dp = 0.0
    for i in range(min(len(pa), len(pb), same + 1)):   # positions with the same history
        if not pa[i] or not pb[i]:
            continue
        n += 1
        agree += pa[i][0][0] == pb[i][0][0]
        lb = dict(map(tuple, pb[i]))
        if pa[i][0][0] in lb:
            dp = max(dp, abs(math.exp(pa[i][0][1]) - math.exp(lb[pa[i][0][0]])))
    ov = len({x[0] for x in pa[0]} & {x[0] for x in pb[0]}) if pa and pb and pa[0] and pb[0] else 0
    print(f'{d:7d} {same:5d} / {min(len(ta), len(tb)):<5d} {agree:4d} / {n:<4d} {dp:15.4f} {ov:22d} / 10')

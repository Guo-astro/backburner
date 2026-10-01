#!/usr/bin/env python3
"""launch-summary.py - the published tables, built only from the raw rows in bench/results/{results,agent}.jsonl
(bench/launch-bench.py, launch-bench-mlx.py, agent-bench.py). Prints Markdown. Smoke and test rows are skipped; when a
config was run more than once, the latest full run is used and the others are listed under "other runs".

  bench/launch-summary.py > docs/launch/RESULTS.md
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, 'bench', 'results')
NAMES = {'stock': 'llama.cpp (stock)', 'stock-spec': 'llama.cpp (stock) + its speculative decoding',
         'mlx': 'MLX (mlx-lm)', 'fork-nospec': 'ours, Mac only, no speculative decoding',
         'fork-mac': 'ours, Mac only', 'fork-phone': 'ours, Mac + iPhone'}
ORDER = ['stock', 'stock-spec', 'mlx', 'fork-nospec', 'fork-mac', 'fork-phone']


def rows(name):
    p = os.path.join(D, name)
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def skip(r):   # rows marked "excluded" stay in the raw files with the reason
    if r.get('excluded'):
        return True
    n = r.get('note', '') or ''
    return 'smoke' in n or 'btest' in n or (r.get('config') == 'mlx' and r.get('kv', '').startswith('f16'))


res = [r for r in rows('results.jsonl') if not skip(r)]
agent = [r for r in rows('agent.jsonl') if not skip(r)]


def latest(kind, config, key=None):
    c = [r for r in res if r['kind'] == kind and r['config'] == config and (key is None or key(r))]
    return c[-1] if c else None


print('# Launch benchmark results\n')
print('Qwen3.8-27B (llama.cpp: IQ4_XS GGUF, KV q8_0; MLX: 4-bit g64, KV 8-bit), MacBook Pro M4 Pro 24 GB, iPhone 17 Pro Max '
      '(A19 Pro) over USB-C 10 Gb/s. Greedy decoding. Raw rows: bench/results/*.jsonl.\n')

print('## Reading a prompt (prefill), tokens per second at each depth\n')
depths = [(0, 4096), (12288, 16384), (28672, 32768), (57344, 61440)]
print('| | ' + ' | '.join(f'{a//1024}k-{b//1024}k' for a, b in depths) + ' | whole prompt from scratch |')
print('|---|' + '---|' * (len(depths) + 1))
for c in ORDER:
    cells = []
    for a, b in depths:
        r = latest('prefill', c, lambda r: r.get('depth0') == a and r.get('depth1') == b)
        cells.append(f'{r["prompt_n"] / (r["prompt_ms"] / 1000):.1f}' if r else '-')
    t = [r for r in res if r['kind'] == 'prefill_total' and r['config'] == c]
    tot = f'{t[-1]["depth1"]//1024}k in {t[-1]["cum_ms"]/1000:.0f} s ({t[-1]["tok_s"]:.1f} tok/s)' if t else '-'
    if any(x != '-' for x in cells):
        print(f'| {NAMES[c]} | ' + ' | '.join(cells) + f' | {tot} |')

print('\n## Writing (decode), tokens per second, 256 tokens after the same question\n')
print('| | at 8k | at 32k | at 60k |\n|---|---|---|---|')
for c in ORDER:
    cells = []
    for d in (8192, 32768, 61440):
        r = latest('decode', c, lambda r: r.get('depth') == d)
        cells.append(f'{r["tok_s"]:.1f}' if r else '-')
    if any(x != '-' for x in cells):
        print(f'| {NAMES[c]} | ' + ' | '.join(cells) + ' |')

print('\n## A coding-agent session (17.5k-token preamble, then 6 turns of a 1.5k-token tool result + 150 tokens answered)\n')
print('| | first answer after | each later turn waits | writing | whole session |\n|---|---|---|---|---|')
for c in ORDER:
    s = [r for r in agent if r['kind'] == 'agent_session' and r['config'] == c]
    for r in s:
        label = NAMES[c] + (f' ({r["note"]})' if r.get('note') and c == 'stock-spec' else '')
        print(f'| {label} | {r["first_wait_s"]:.0f} s | {r["turn_wait_s"]:.1f} s | {r["gen_tok_s"]:.1f} tok/s | {r["wall_s"]:.0f} s |')

long = [r for r in rows('long.jsonl') if not r.get('excluded')]
if long:
    print("\n## Past 64k: Mac + iPhone (q8_0, the phone holds the oldest part) vs Mac alone (q4_0, the only way 128k fits in 24 GB)\n")
    print('| | reading 0-64k | reading 64k-128k | whole 128k from scratch | writing at 128k | recall (3 facts) |\n|---|---|---|---|---|---|')
    for c, label in (('phone', 'Mac + iPhone, q8_0'), ('mac-q4', 'Mac alone, q4_0')):
        pre = [r for r in long if r['kind'] == 'prefill' and r.get('config', 'phone') == c]
        if not pre:
            continue
        lo = [r for r in pre if r['depth1'] <= 65536]; hi = [r for r in pre if r['depth0'] >= 65536]
        rate = lambda rs: f"{sum(r['prompt_n'] for r in rs) / (sum(r['prompt_ms'] for r in rs) / 1000):.1f} tok/s" if rs else '-'
        dec = [r for r in long if r['kind'] == 'decode' and r.get('config', 'phone') == c]
        rec = [r for r in long if r['kind'] == 'recall' and r.get('config', 'phone') == c]
        writing = f"{dec[-1]['tok_s']:.1f} tok/s" if dec else '-'
        recall = f"{rec[-1]['found']} of {rec[-1]['of']}" if rec else '-'
        print(f"| {label} | {rate(lo)} | {rate(hi)} | {pre[-1]['cum_ms'] / 1000:.0f} s | {writing} | {recall} |")

sess = [r for r in rows('session.jsonl') if not r.get('excluded') and r['kind'] == 'session']
if sess:
    print('\n## A coding-agent session sent the way omp sends it (medium thinking, omp\'s sampling, streamed)\n')
    print('omp\'s system prompt and 12 tools + project notes (~20k tokens), then 3 turns that each bring a ~1.5k-token tool result. '
          'Up to 1,024 tokens per answer (thinking + answer). Sampled, so the answers differ between runs: compare rates, not text. '
          'Memory, swap and GPU power sampled once a second.\n')
    print('| | first answer starts after | later turns start after | writing | token gaps (median / worst p95) | draft tokens accepted '
          '| GPU power | GPU energy per token | server memory | swap during the session | phone heat (0 = normal) |')
    print('|---|---|---|---|---|---|---|---|---|---|---|')
    for c, label in (('stock', NAMES['stock']), ('fork-mac', NAMES['fork-mac']), ('fork-phone', NAMES['fork-phone'])):
        for r in [x for x in sess if x['config'] == c][-1:]:
            acc = f"{100 * r['draft_accept']:.0f}%" if r.get('draft_accept') is not None else '-'
            heat = '-' if r.get('phone_thermal_max') is None else str(r['phone_thermal_max'])
            print(f"| {label} | {r['first_wait_s']:.0f} s | {r['turn_wait_s']:.1f} s | {r['gen_tok_s']:.1f} tok/s | "
                  f"{r['gap_p50_ms']:.0f} / {r['gap_p95_ms']:.0f} ms | {acc} | {r['gpu_w_mean']:.0f} W | {r['gpu_j_per_token']:.1f} J | "
                  f"{r['server_gb_peak']:.1f} GB | {r['swap_gb_start']:.1f} -> {r['swap_gb_peak']:.1f} GB | {heat} |")

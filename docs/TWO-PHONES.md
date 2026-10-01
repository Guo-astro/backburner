# Two iPhones: design (2026-10-01)

Status: **A is built** (llama.cpp 879b48a68 + scripts): `LLAMA_KV_REMOTE` takes a list, phone-up.sh finds every phone with
Sidecar open, serve.sh gives each an equal share. Checked on this Mac with two loopback phone servers (greedy tokens
identical to Mac-only, same error as one phone). Not yet run on two real phones (needs the second cable). B is not built.

Two ways a second phone helps. They don't conflict: like split prefill and phone-held KV with one phone, they are used at
different context lengths. Numbers marked [M] are measured with one phone; [E] are estimates.

## A. Past 64k: split the old context across both phones (build first)

Today one phone holds every KV page older than the Mac's 64k cells and computes attention over them; the Mac merges that
partial result with its own (log-sum-exp merge, exact).
With two phones, each holds half the old pages and computes half; the Mac merges three partials instead of two.

- What changes: `LLAMA_KV_REMOTE` takes a list of endpoints; pages are assigned by position range (phone 1 the oldest half,
  phone 2 the rest); every remote attention call goes to both phones in parallel; the merge takes N partials. The phone side
  doesn't change at all (each phone already serves "attention over the pages I hold").
- What it buys:
  - Capacity: two phones' memory. At q8_0 one A19 Pro holds ~131-165k old tokens [M: cap math], so 262k (the model's
    maximum) fits with room to spare.
  - Prefill past 64k: per 256-token call at 140k, the phone computes for 124 ms + 26 ms link [M]. Halving the compute
    moves 140k prefill from 70.2 tok/s toward the "instant phone" ceiling of 76.5 [M ceiling, E result: ~73-75].
  - Decode past 64k: the ~6% phone overhead roughly halves [E].
- Effort: small to moderate. Most of it is the Mac's remote-KV client; the merge already exists.

## B. Under 64k: a three-stage reading line Mac -> iPhone -> iPhone

Today: Mac layers 1-40, phone 41-64, pipelined in 256-token chunks [M: +16% on a cold 60k read, ~+27% per step deep in].
With two phones: Mac 1-L1, phone A L1-L2, phone B L2-64. Both phones connect only to the Mac, so the Mac relays each chunk's
residual from A to B (2.6 MB per chunk, ~3 ms on 10 Gb/s).

- What changes: the phone's tail server gets a "middle stage" mode (run its layers, return the residual instead of logits);
  the Mac's split client drives two workers and keeps two mirrors in sync; a split file per stage (`split-gguf.py` already
  cuts any layer range); the layer split is chosen by speed (an A19 runs a layer at ~0.69x the Mac's speed [M]).
- What it buys: ideal per-layer throughput 1 + 0.69 + 0.69 = 2.38x the Mac alone vs 1.69x with one phone [E, ideal];
  fill/drain and the every-2,048-token hand-off eat part of it. Realistic guess: +15-25% over one phone [E].
- Effort: larger than A: a new worker mode, two mirrors, and the hand-off every 2,048 tokens happens with both phones.

## Order

1. A first: small, and it completes the full-context story (262k at full quality).
2. Measure A at 128k and 200k with the same scripts (`bench/long-bench.py`).
3. B after, if the launch numbers say prefill speed under 64k is what people care about most (it probably is: most
   sessions are under 64k).

## Hardware notes

- Each phone on its own USB-C port, each with a 10 Gb/s data cable.
- Two A19 Pro phones on hand; the A18 Pro also works (slower: L=52 split measured).
- Both need Sidecar open and unlocked; both heat up, so a fan helps long runs.

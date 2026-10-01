# Backburner

Your iPhone helps your Mac run Qwen3.8-27B locally. Plugged in over a 10 Gb/s USB-C cable, the iPhone reads prompts
together with the Mac (the Mac runs layers 1-40, the iPhone 41-64) and holds the oldest part of the context once the Mac
runs out of room (past 64k tokens on a 24 GB Mac).

Status: private, pre-release. Setup steps and the benchmark write-up are in progress.

- `llama.cpp/`: the engine, a llama.cpp fork (submodule: StayLameBro/backburner-llama.cpp)
- `ios/Backburner/`: the iPhone app
- `scripts/serve.sh`: the Mac server (OpenAI-compatible), uses the iPhone when it's plugged in
- `bench/`: the benchmarks and their raw results (`bench/results/*.jsonl`)

Tested on a MacBook Pro M4 Pro (24 GB) with an iPhone 17 Pro Max (A19 Pro) and an iPhone 16 Pro (A18 Pro).

Built with heavy help from Claude Opus 5.5.

MIT license (llama.cpp keeps its own MIT license).

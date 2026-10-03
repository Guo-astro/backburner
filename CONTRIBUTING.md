# Contributing to Backburner

Thanks for helping! Bug fixes, new devices (iPads, Android, more phones), kernels, docs and test results are all welcome.

## The easiest contribution: results

Run it on your hardware and [post your results](https://github.com/StayLameBro/backburner/issues/new?template=results.yml),
good or bad. Numbers from Macs, phones and iPads we don't have are the most useful thing right now.

## Sending a change

1. Fork the repo and make a branch.
2. Keep one change per pull request, and say in the description what it does and how you measured it.
3. Open a pull request against `main`. Changes land through reviewed pull requests only.

For bigger changes (a new device type, a new engine, a new protocol), open an issue first so we can agree on the shape
before you spend time on it.

## What a change has to show

- **Same answers.** Anything that touches the model's math (kernels, split prefill, the phone-held context) must keep greedy
  output identical, or explain exactly where and why it differs. `bench/launch-bench.py` records greedy runs and
  `bench/launch-quality.py --a <before> --b <after>` compares them; post its output in the pull request.
- **Measured speed.** Speed claims come with the command, the hardware, and before/after numbers from the same build and
  settings (`bench/turn-bench.py`, `bench/session-bench.py`, `bench/long-bench.py`). Note anything else that was running.
- **Nothing breaks without the phone.** `PHONE=0 scripts/serve.sh` (the Mac alone) must keep working.

## Sign-off

Add a sign-off line to each commit (`git commit -s`):

    Signed-off-by: Your Name <you@example.com>

It certifies that you wrote the change (or have the right to submit it) and that it can be shared under this project's
license, as described in the [Developer Certificate of Origin](https://developercertificate.org/).

## License and credit

Backburner is MIT licensed, and contributions come in under the same MIT license. Your commits keep your name, and people
who port Backburner to new devices or land significant work are credited in the README.

Forks are welcome under the MIT license. If you start a separate project from it, please give it a different name and link
back here.

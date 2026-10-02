#!/bin/bash
# phone-ane.sh IP [--off]: push the ANE page template (Documents/anekv/tmpl16k.mlmodelc; the app's phone-attn then serves the
# oldest 16k-key pages of each layer on the Neural Engine, docs/ane-kv-plumbing.md) and relaunch the app. Builds the template
# first if missing (phone-attn/ane-kv/build.py, needs coremltools: pip install coremltools). --off: push an empty anekv dir (engine off).
set -eu
cd "$(dirname "$0")/.."
IP=$1
TM=build/ane-kv/tmpl/kv_N16384_R48_fp16_pfix_cinput.mlmodelc
TMP=$(mktemp -d)/anekv; mkdir -p "$TMP"
if [ "${2:-}" != --off ]; then
  [ -d "$TM" ] || "${PY:-python3}" phone-attn/ane-kv/build.py build/ane-kv/tmpl --keys 16384 --rows 48 --wq fp16 --pfix --center input
  cp -R "$TM" "$TMP/tmpl16k.mlmodelc"
fi
python3 scripts/phone-push.py "$IP" "$TMP" anekv | tail -1
exec scripts/phone-relaunch.sh "$IP"

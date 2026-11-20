#!/bin/sh
# The package's gate: the self-checks under both execution modes, and the
# generated bindings up to date.
#
#     sh scripts/run_tests.sh
#
set -eu

cd "$(dirname "$0")/.."

echo "== generated bindings"
python3 scripts/generate_bindings.py --check

echo "== self-checks (in-process)"
goose run tests/test_imgui.goose

echo "== self-checks (native)"
goose build tests/test_imgui.goose
./tests/test_imgui

echo "ok: bindings and tests"

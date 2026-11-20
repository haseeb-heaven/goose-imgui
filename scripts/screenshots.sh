#!/bin/sh
# Builds every example and captures its screenshot.
#
# Each example renders offscreen, runs at least 30 frames and writes one real
# frame as a PNG, so the images in screenshots/ are the examples' own output and
# not hand-drawn mockups. Run from the repository root:
#
#     sh scripts/screenshots.sh
#
set -eu

cd "$(dirname "$0")/.."

mkdir -p screenshots

capture() {
    name="$1"
    size="$2"
    echo "== $name ($size)"
    goose build "examples/$name/main.goose"
    "./examples/$name/main" --shot "screenshots/$name.png" --frames 30 --size "$size"
}

capture hello 480x240
capture calculator 760x430
capture showcase 880x470
capture system_monitor 980x640
capture node_graph 1000x620

for image in screenshots/*.png; do
    bytes=$(wc -c < "$image" | tr -d ' ')
    if [ "$bytes" -lt 4096 ]; then
        echo "error: $image looks empty ($bytes bytes)" >&2
        exit 1
    fi
    echo "$image: $bytes bytes"
done

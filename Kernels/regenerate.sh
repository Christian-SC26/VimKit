#!/bin/sh
# Regenerates the C that VimCore links from the Goose kernels.
# Needs the Goose compiler (https://aardappel.github.io/goose/) on PATH.
# The generated files are committed, so building VimKit does not need Goose.
set -e
cd "$(dirname "$0")"
out=../Sources/VimGooseKernels
goose -o "$out/fold_blocks.c" --header "$out/include/VimGooseKernels.h" fold_blocks.goose
# The rest of the runtime (data stacks, OS layer), linked with every Goose program.
goose --emit-runtime "$out/goose_runtime.c"
echo "Generated with $(goose --version)" > "$out/GENERATED.txt"

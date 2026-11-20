#!/bin/sh
# Downloads the Silero voice detector (about 2 MB, MIT licence) in the form sherpa-onnx reads
# into App/Resources/SileroVAD, from where it is bundled into the app. Without it the app
# still listens, but tells speech from other noise by loudness alone.
set -eu
target="$(cd "$(dirname "$0")/.." && pwd)/App/Resources/SileroVAD"
mkdir -p "$target"
if [ ! -s "$target/silero_vad.onnx" ]; then
    echo "fetch  silero_vad.onnx"
    curl --fail --location --silent --show-error \
        -o "$target/silero_vad.onnx.part" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    mv "$target/silero_vad.onnx.part" "$target/silero_vad.onnx"
fi
ls -l "$target/silero_vad.onnx"

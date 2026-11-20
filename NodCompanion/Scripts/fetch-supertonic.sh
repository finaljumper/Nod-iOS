#!/bin/sh
# Downloads the Supertonic 3 voice model (int8 build for sherpa-onnx, about 145 MB) into
# App/Resources/Supertonic3, from where it is bundled into the app. The files are not kept
# in the repository. The weights are under the BigScience OpenRAIL-M licence.
set -eu
repo="csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11"
target="$(cd "$(dirname "$0")/.." && pwd)/App/Resources/Supertonic3"
mkdir -p "$target"
for file in duration_predictor.int8.onnx text_encoder.int8.onnx vector_estimator.int8.onnx \
            vocoder.int8.onnx tts.json unicode_indexer.bin voice.bin LICENSE; do
    if [ -s "$target/$file" ]; then
        echo "have   $file"
    else
        echo "fetch  $file"
        curl --fail --location --silent --show-error --output "$target/$file.part" \
            "https://huggingface.co/$repo/resolve/main/$file"
        mv "$target/$file.part" "$target/$file"
    fi
done
echo "Supertonic 3 is in $target"

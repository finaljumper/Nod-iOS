# VoiceASRBenchmark

A SwiftUI app for iPhone, iPad and Mac that runs the same prerecorded speech through four
on-device engines and reports accuracy, latency and resource use for English, Russian, Korean
and mixed-language recordings. The engines are Apple's SpeechAnalyzer with its
`SpeechTranscriber` module, the same with its `DictationTranscriber` module, WhisperKit, and
Reson8's Rumble-2-Flash running on MLX.

It benchmarks speech recognition only. There is no assistant, no TTS and no cloud API in it.

## Status

The project was written in an environment without a Mac. On 19 November 2026 it was built and
exercised on a Mac for the first time (Xcode 27.2, Swift 6.4.2, macOS 27.2, WhisperKit 1.1.1).

| Part | State |
| --- | --- |
| `ASRBenchCore` (protocol, audio pipeline, manifest, metrics, runner, export) | Builds on macOS, where its 96 unit tests pass. Written and first tested on Linux |
| `asrbench-dataset` command-line tool | Builds; `validate` exercised on macOS |
| `ASRBenchEngines` (Apple and WhisperKit adapters) | Compile against the real Speech framework and WhisperKit; 6 unit tests pass. On a Mac, SpeechTranscriber transcribed English and DictationTranscriber transcribed English, Russian and Korean, each in batch and streaming mode. The WhisperKit adapter downloaded `openai_whisper-base` and transcribed English, Russian and Korean in batch and simulated-streaming mode in the iOS Simulator |
| `ASRBenchMLXEngines` (Rumble-2-Flash adapter) | Compiles for macOS, iOS and the iOS Simulator; 8 unit tests pass. On a Mac it downloaded the model and transcribed English, Russian, Korean and mixed-language clips in batch and simulated-streaming mode. **Not run on an iPhone or iPad.** It cannot run in the iOS Simulator, where it reports itself unavailable |
| SwiftUI views | Compile for macOS and iOS. All three tabs were exercised in the iPhone simulator; the Mac app and the export buttons were not |
| Xcode project | `xcodegen generate` (2.46.0) works; the app builds for macOS and the iOS Simulator |
| Benchmark results | **None exist.** The runs above used a dozen clips of synthetic macOS speech to prove the harness works. No real recordings exist yet, and nothing has run on an iPhone or iPad |

Two bugs found on first run are fixed: every memory figure was exported as roughly zero, and a
downloaded WhisperKit model was forgotten whenever the app was reinstalled.

## Getting started

Requirements: Xcode 26 or later (the Apple engine needs the iOS 26 / macOS 26 SDK),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), a device on iOS 26 / macOS 26 for the Apple
engine. WhisperKit alone runs from iOS 17 / macOS 14.

Run the core tests:

```bash
swift test
```

Generate and open the Xcode project:

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open VoiceASRBenchmark.xcodeproj
```

Set your development team on the `VoiceASRBenchmark` target, then build and run. The scheme's
Run action uses the Release configuration, because Debug timings are not representative.

In the app:

1. **Setup tab**, while online: check what each engine supports on this device, then
   *Download models and speech assets*. This is the only step that uses the network.
   Rumble-2-Flash is a 692 MB download.
2. **Benchmark tab**: import a dataset folder (see `Docs/DATASET.md`), switch engines on or off, choose the
   WhisperKit model and the mode, then *Run benchmark*.
3. **Results tab**: comparison by language, per-recording transcripts with a word diff, and
   export as JSON and CSV.

## Layout

```
Package.swift                     Swift package: core, engines, dataset tool, tests
project.yml                       XcodeGen specification of the app target
Sources/ASRBenchCore/             platform-independent, no dependencies
  Recognition/                    SpeechRecognitionEngine protocol, capabilities, results
  Audio/                          WAV decoder, resampler, real-time replay
  Benchmark/                      manifest, accuracy, latency, resources, runner, export
Sources/ASRBenchEngines/          AppleSpeechAnalyzerEngine (both Apple modules), WhisperKitEngine, platform helpers
Sources/ASRBenchMLXEngines/       RumbleFlashEngine (Rumble-2-Flash through mlx-audio-swift)
Sources/asrbench-dataset/         validate and scaffold dataset manifests
App/                              SwiftUI app: view model and three screens
App/Resources/Dataset/            sample manifest: sentences to record, no audio
Tests/ASRBenchCoreTests/          unit tests
Docs/FEASIBILITY.md               what was verified about both engines, and their limits
Docs/METHODOLOGY.md               every metric defined, and how to run comparably
Docs/DATASET.md                   manifest schema, recording and import guide
```

The engines sit behind `SpeechRecognitionEngine` and depend only on `ASRBenchCore`, so the
adapter of the winning engine can be lifted into the assistant unchanged.

## Design decisions worth knowing

- **Engines receive decoded samples, not a file URL.** The runner decodes each file once and
  derives every engine's input from the same samples with one deterministic resampler. This
  guarantees identical audio and keeps decoding out of the inference timings. A
  `transcribe(audioURL:languageHint:)` convenience exists for use outside the benchmark.
- **Unsupported is a status of its own.** A language or capability an engine does not offer is
  recorded as `unavailable` with the reason, is never executed and never counts as an error.
- **Rumble-2-Flash streaming is simulated too.** The model transcribes a whole clip at once and
  does so in a fraction of a second, so the adapter decodes the audio received so far again
  after every second of new audio. The stable part of a partial is what two consecutive
  decodes agree on.
- **mlx-audio-swift is pinned to a commit of a fork.** Rumble-2-Flash needs a fix that is an
  open pull request (number 412) against `Neywa-Labs/mlx-audio-swift`. `Package.swift` pins the
  head of that pull request by revision; move to an upstream release once it is merged.
- **WhisperKit streaming is simulated and labelled so.** Whisper has no incremental decoder;
  the adapter re-decodes the growing buffer, the scheme WhisperKit itself uses for microphone
  input. Apple's streaming is native.
- **No engine supports code-switching by design.** Both Apple modules take one locale per
  session and have no language detection; Whisper assumes one language per 30-second window. The results
  separate hinted runs, auto-detect runs and a per-script error breakdown to show what happens.
- **Memory in interleaved order includes all loaded engines.** Use engine-block order for
  per-engine memory and battery. Interleaved order is the default because it spreads thermal
  drift evenly.
- **The engines target uses Swift 5 language mode**, the core uses Swift 6. WhisperKit's types
  are not fully `Sendable`, and the adapters could not be compiled here.

## Known gaps

- Rumble-2-Flash has not been run on an iPhone or iPad. On a Mac the process peaked at 1.6 to
  1.9 GB while it ran, which may exceed what iOS allows an app on some devices. The app does
  not request the increased-memory-limit entitlement.
- The Rumble-2-Flash weights are a community conversion (`TypeWhisper/Rumble-2-Flash-8bit`),
  not a release by Reson8, and are downloaded at run time from Hugging Face.
- Rumble-2-Flash returns text only: no segment or word time ranges.
- `DictationTranscriber` runs with punctuation on and no content hints. Its presets and its
  `frequentFinalization` option are not exposed.
- Apple's model storage size and a forced cold start cannot be measured from an app.
- Memory and CPU are measured for the app's process; work done in a system service is not seen.
- The WhisperKit version is not available at run time; exports refer to `Package.resolved`.
- Endpoint detection (deciding that the speaker has finished) is outside the benchmark.

# Phase 1: research and feasibility

Findings from November 2026. Each item says where it was verified, because the development
environment this was written in had no Mac attached: nothing here was checked against an
installed Xcode or SDK, and no code was run on Apple hardware.

| Source | What it verified |
| --- | --- |
| Apple's Speech framework documentation (developer.apple.com) | Every SpeechAnalyzer symbol the adapter uses, with its signature and OS availability |
| WhisperKit source, `main` at commit `9f99b5c` (10 Oct 2026) and tag `v1.1.1` | Every WhisperKit symbol the adapter uses |
| Swift 6.2.4 on Linux | The platform-independent core compiles and its 95 unit tests pass; the two adapters and the view model type-check against stubs that copy those signatures |
| Not verified | The installed Xcode and SDK versions, the SwiftUI views (never compiled), and everything that needs a device: which locales SpeechTranscriber offers, real timings, real accuracy |

## Apple SpeechAnalyzer

- **OS support.** `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` and `AnalyzerInput` are
  available from iOS 26, iPadOS 26, macOS 26, visionOS 26 and tvOS 26. The app deploys to iOS 17
  and macOS 14 and checks at run time; on older systems the Apple engine reports itself
  unavailable and WhisperKit still runs.
- **Device support.** `SpeechTranscriber.isAvailable` can be `false` on hardware that cannot run
  the model. Apple points such devices to `DictationTranscriber`, which has no such flag and a
  different list of locales. The benchmark runs it as a separate engine.
- **On-device only.** The API has no server mode, so there is no cloud fallback to disable.
- **Languages.** The documentation does not list supported locales. They are a run-time query:
  `SpeechTranscriber.supportedLocales` (downloadable) and `installedLocales` (present).
  **Whether English, Russian and Korean are supported on your devices is not established here.**
  The Setup tab shows the answer per language, and an unsupported language is recorded as
  unavailable, never as a failed recognition.
- **Language assets.** Models are downloaded and stored by the system and shared between apps.
  `AssetInventory.status(forModules:)` reports `unsupported`, `supported` (needs download),
  `downloading` or `installed`. The app installs assets only in the explicit setup step.
  An app has a limited number of locale reservations (`AssetInventory.maximumReservedLocales`);
  three locales should fit but this is worth checking on device.
- **One locale per transcriber.** A `SpeechTranscriber` is created for one `Locale`. There is no
  language detection and no multi-locale mode. For code-switched speech the benchmark can run
  one pass per language of the recording (`alternates` hint mode) to show what each locale
  makes of it.
- **Streaming.** Native. With `.volatileResults` the transcriber emits tentative results that are
  later replaced by final ones (`result.isFinal`). `.fastResults` trades accuracy for
  responsiveness and is a separate, optional engine configuration in the app.
- **Timestamps.** Each result has an audio `range`. With `.audioTimeRange`, runs of the result
  text carry time ranges.
- **Audio format.** The analyzer does not convert audio. The adapter asks
  `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` and builds buffers in that format.
- **iOS 27 additions not used.** `AnalyzerInputConverter` and the input sequence providers are
  iOS 27 and later. They are avoided on purpose: the benchmark converts audio itself so both
  engines receive the same samples, and the code stays compatible with iOS 26.

### Limits that affect the benchmark

- **Model storage size cannot be measured**: assets are outside the app's container.
- **Cold start cannot be forced**: an app cannot unload system-managed models. The first load
  after launching the app is the closest thing to a cold start.
- **Process metrics may undercount.** Memory and CPU are measured for the app's process. If the
  Speech framework does part of its work in a system service, that part is invisible to the
  app. Check with Instruments before drawing conclusions from Apple's memory and CPU figures.

## WhisperKit

- **Package.** WhisperKit now ships from `https://github.com/argmaxinc/argmax-oss-swift`
  (the old `argmaxinc/WhisperKit` URL redirects there). The package also contains TTSKit and
  SpeakerKit; this project links only the `WhisperKit` product. Latest release: `v1.1.1`.
  `Package.swift` requires `from: "1.1.0"`; commit `Package.resolved` to pin the exact version.
- **Platforms.** iOS 16, macOS 13 and later.
- **Models.** Core ML models come from the Hugging Face repository `argmaxinc/whisperkit-coreml`.
  `WhisperKit.recommendedModels()` returns the models its built-in table considers suitable
  for the current device. In the part of that table that was read, M1-class devices default to
  `openai_whisper-large-v3-v20240930_626MB` (the compressed September 2024 large-v3 release),
  and A16 to A18 phones default to `openai_whisper-base` while also supporting the compressed
  `large-v3` variants. The entry for the M4 was not checked; the app shows what the table
  returns on the device it runs on.
  The app lists the multilingual ones and lets you pick. English-only (`.en`) and distilled
  English models are excluded because they cannot transcribe Russian or Korean.
- **Offline use.** `WhisperKit.download(variant:)` fetches a model. The tokenizer is fetched
  separately on the first load, so the setup step downloads the model and then loads it once.
  After that, loading with `download: false` and a local `modelFolder` needs no network.
- **Languages.** Multilingual Whisper models cover English, Russian and Korean and can detect the
  language. Detection happens once per 30-second window.
- **Streaming.** Whisper is not an incremental model. WhisperKit's `AudioStreamTranscriber`
  reaches "streaming" by decoding the growing audio buffer again and again and confirming all
  but the last segments. It is tied to the microphone, so the benchmark reimplements the same
  scheme on replayed audio and labels it **simulated streaming** everywhere. Consequence: the
  first partial cannot arrive before the first decode, which waits for one second of audio by
  default.
- **Code-switching.** Whisper conditions each window on a single language token. Mixed-language
  speech is outside its intended use; the other language may be translated, transliterated or
  dropped. The per-script error breakdown is there to show exactly this.
- **Engine version at run time.** WhisperKit exposes no version constant, so exports record the
  package name and point to `Package.resolved`.

## What this means for the assistant

Neither engine handles English–Russian–Korean code-switching as a designed feature. Apple needs
the language up front; Whisper guesses one language per window. The benchmark therefore reports
three things separately: accuracy with the right hint, accuracy with no hint (Whisper only),
and for mixed recordings which script's words were lost. If Apple wins on single-language
accuracy and latency, the assistant will still need a language decision per utterance, which
is a design question outside this benchmark.

## First findings on a Mac (19 and 20 November 2026)

Checked on one Mac running macOS 27.2 with the package's own adapters. iPhone and iPad may
differ and still have to be checked in the Setup tab.

- **SpeechTranscriber has no Russian.** It reported 45 locales, among them `en-US` and `ko-KR`,
  and no Russian one. English assets were already installed; Korean needs a download. Russian
  is a required language, so on this evidence SpeechTranscriber alone cannot be the assistant's
  recogniser.
- **DictationTranscriber covers all three languages.** It reported 54 locales, among them
  `en-US`, `ru-RU` and `ko-KR`. English and Korean assets were installed; the Russian ones took
  13 s to download. Of the four synthetic Russian clips it transcribed two without a word error,
  and in the other two the only differences were numbers written as digits. It was added as a
  third engine, `apple-dictationtranscriber`.
- **DictationTranscriber's first partial arrives after 0.6 to 0.8 s** on most clips, against
  4.0 s for SpeechTranscriber's default and 1.1 s with `.fastResults`.
- **DictationTranscriber dropped most of two of the four synthetic Korean clips** (the
  conversational and the long one). Whether that is the model or the synthetic voice is unknown;
  check it with real Korean recordings before drawing a conclusion.
- **The two modules write differently.** DictationTranscriber returned no sentence-final
  punctuation and no punctuation at all in Russian, although punctuation was requested.
  Numbers come back as digits or words depending on the module and the sentence. The relaxed
  error rates ignore punctuation; number formatting still counts as errors.
- **SpeechTranscriber's first partial takes about 4 s by default.** In streaming mode with `.volatileResults`
  the first partial arrived 4.0 s after the audio started, on every clip longer than that.
  With `.fastResults` added it arrived after 1.1 s. Benchmark Apple streaming with the
  *fast results* option on as well as off.
- **Apple's inference is outside the app's process.** Peak process memory during Apple runs was
  10 to 15 MB, so the memory and CPU figures for the Apple engine do not include the model.
- **WhisperKit recommends `openai_whisper-base`** on this Mac and in the iOS Simulator; larger
  models are listed as supported and have to be picked by hand.

## Rumble-2-Flash, tried on a Mac (20 November 2026)

[Rumble-2-Flash](https://huggingface.co/Reson8/Rumble-2-Flash) is a 0.5B-parameter speech
recognition model from Reson8 in the Qwen3-ASR architecture, Apache 2.0, released on
18 November 2026. Its tags list 45 languages, among them English, Russian and Korean. It was
first run outside the app, with the Python package, to decide whether it is worth integrating;
the table below is from that run. It was then added as the engine `rumble/Rumble-2-Flash-8bit`
(see the end of this section).

How it was run: the community conversion `TypeWhisper/Rumble-2-Flash-8bit` (715 MB) with the
Python package mlx-audio 0.6.3, on the same Mac as above, over 17 clips of synthetic macOS
speech (the 12 single-language clips plus 5 mixed-language ones, in which each script is spoken
by the voice of its language). Scores come from this package's `AccuracyMetrics`, pooled over
the clips of a group, relaxed normalisation. Apple engines ran through the benchmark runner
with the primary language as the hint.

| Engine | English WER / CER | Russian | Korean | Mixed-language |
| --- | --- | --- | --- | --- |
| Apple SpeechTranscriber | 5.9 % / 3.1 % | unsupported | 20.4 % / 3.1 % | 57.6 % / 54.6 % (3 of 5 clips; 2 have Russian as primary) |
| Apple DictationTranscriber | 8.2 % / 5.0 % | 6.6 % / 8.9 % | 68.5 % / 54.3 % | 44.8 % / 45.6 % |
| Rumble-2-Flash, language hint, numbers as digits | 5.9 % / 3.6 % | 6.6 % / 8.9 % | 20.4 % / 3.1 % | 31.0 % / 20.3 % |
| Rumble-2-Flash, no hint, numbers as digits | 8.2 % / 4.2 % | 6.6 % / 8.9 % | 20.4 % / 3.1 % | 32.8 % / 21.7 % |
| Rumble-2-Flash, language hint, numbers as words | 7.1 % / 6.2 % | 1.6 % / 0.6 % | 16.7 % / 1.6 % | 27.6 % / 17.5 % |

- **It writes each language in its own script within one sentence.** On the English–Russian–Korean
  clip it scored 12.5 % WER; both Apple engines scored above 80 %, because they force everything
  into one language. This is the only engine tried so far that does this.
- **It is not immune.** Two Russian words inside an English command came back as English
  sound-alikes ("molecule", "clip"), and Korean words inside a Russian sentence were written
  out in Cyrillic.
- **Speed and memory on the Mac:** about 0.12 to 0.15 s per clip, 0.7 s to load, 2.7 s for the
  first transcription, 1.6 GB peak MLX memory. No iPhone figures exist.
- **No partial results.** It returns one final transcript per clip, so there is no live
  transcript while speaking.
- **Number format is a setting** (digits or words), which removes most of the formatting errors
  the Apple engines score against the Russian and Korean references.
- **Route to iPhone:** mlx-audio-swift, with a fix that is still an open pull request. Other
  community conversions exist for sherpa-onnx, llama.cpp and LiteRT; none was tried.

These numbers come from 17 synthetic clips and decide nothing. They were the reason to add
the model to the benchmark, not a result of it.

### As an engine of the benchmark

The adapter `RumbleFlashEngine` runs the same weights through mlx-audio-swift. On the same Mac
and clips, through the benchmark runner:

- **Same transcripts as the Python run**, for example 12.5 % WER on the English–Russian–Korean
  clip.
- **Batch:** 0.10 to 0.45 s per clip once warm, 0.9 s for the 13-second clip on its first
  decode. The first transcription after loading took 5.6 s because MLX compiles its GPU
  kernels; loading itself took 0.3 to 1.4 s.
- **Simulated streaming:** first partial 1.1 s after the audio starts, first stable text after
  2.1 s, final transcript 0.1 to 0.9 s after the end of the audio.
- **Memory:** the app's process peaked at 1.6 to 1.9 GB during a run. Unlike Apple's engines,
  this model runs inside the app's process, so the figure is complete.
- **Disk:** 692 MB. The downloader's second copy of the files is deleted after the download.
- **Language detection:** correct on all 12 single-language clips. Mixed clips are reported as
  one language.


## Open items

1. Run the Setup tab on the target iPhone and iPad and note which of `en`, `ru`, `ko`
   SpeechTranscriber and DictationTranscriber offer there.
2. Record the real corpus (see `DATASET.md`) and run the benchmark in a Release build on devices.
3. Run Rumble-2-Flash on the target iPhone and iPad. Whether it fits in the memory iOS allows
   an app is the open question; if it does not, try the increased-memory-limit entitlement or
   a smaller quantization.
4. Replace the pinned fork of mlx-audio-swift with an upstream release once its pull request
   412 is merged.

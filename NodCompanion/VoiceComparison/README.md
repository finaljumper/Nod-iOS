# Voice comparison

## Decision (20 November 2026)

The voice for Nod's replies will be **Supertonic 3**. It was not tested here: it is already in
use in another of the owner's apps (LangPal), where it runs through sherpa-onnx 2.0.0 with
`csukuangfj/onnxruntime-libs` 1.28.2 and model files bundled in the app. English and Korean are
the languages that matter now; Russian is no longer essential.

What follows is the comparison made before that decision, between Apple's system voices and
Qwen3-TTS. It stays as the record of why Qwen3-TTS was not chosen. Supertonic 3 does not appear
in it or on the listening page.

Facts about Supertonic 3 gathered while looking into it, none of them measured here:

- 31 languages, among them English, Korean and Russian. The language is given per call.
- About 99M parameters. The official ONNX files are 398 MB; the int8 build for sherpa-onnx is
  145 MB. Ten built-in voices (F1 to F5, M1 to M5), 44.1 kHz output.
- It generates a whole text chunk at once and does not stream, so speaking sentence by sentence
  is what keeps the delay short.
- The weights are under the BigScience OpenRAIL-M licence. Supertone archived the open-source
  project on 9 September 2026 and announced no further development or support for it.
- Microsoft's `onnxruntime` and `onnxruntime-swift-package-manager` repositories returned
  "not found" on GitHub from about 17 November 2026, for reasons not known. Supertone's own
  Swift example depends on the second one and does not build today. The sherpa-onnx route does
  not use those repositories and both of its repositories were reachable on 20 November 2026.
- A Core ML conversion also exists (`FluidInference/supertonic-3-coreml`, used by the FluidAudio
  framework), as a fallback that needs no ONNX Runtime.


Which voice should speak Nod's replies? Six sentences (English, Russian, Korean and three
mixed-language ones) were spoken by Apple's system voices and by one neural model, on a Mac, on
20 November 2026. Open `index.html` in a browser to listen; the clips are also in `samples/`.

This was run on a Mac with the Python package mlx-audio 0.6.3. Nothing was run on an iPhone.
Nobody has listened to the clips yet: "intelligible" below means that a speech recogniser
(Rumble-2-Flash) could transcribe the clip back, which says nothing about how pleasant a voice
sounds.

## What was compared

| Voice | Result |
| --- | --- |
| Apple system voices (`AVSpeechSynthesizer`; standard-quality Samantha, Milena, Yuna) | Compared. This is what the app uses |
| Qwen3-TTS 0.6B, 8-bit (`mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`) | Compared, in three ways of handling mixed sentences |
| Chatterbox (`mlx-community/Chatterbox-TTS-8bit`) | Dropped: this checkpoint is English-only and refused Russian and Korean. It also has no built-in voice and delivered its audio in one piece |
| OmniVoice (`mlx-community/OmniVoice-8bit`) | Not measured: mlx-audio 0.6.3 could not load this 8-bit checkpoint. It generates a whole clip at once, so it cannot start speaking early |

The other text-to-speech models in mlx-audio-swift were not tried. Where their documentation
lists languages, Russian or Korean is missing; where it does not, as for VoxCPM2 (2.2 GB) and
Fish Speech, nothing is known.

## Results

Word error / character error of the clip transcribed back (lower is better):

| Sentence | Apple voices | Qwen3, one language | Qwen3, auto language | Qwen3, split by script |
| --- | --- | --- | --- | --- |
| English | 6 % / 1 % | 6 % / 1 % | 6 % / 1 % | 6 % / 1 % |
| Russian | 13 % / 9 % | 7 % / 2 % | 0 % / 0 % | 0 % / 0 % |
| Korean | 31 % / 5 % | 0 % / 0 % | 19 % / 5 % | 6 % / 2 % |
| Russian with English words | 8 % / 2 % | 15 % / 24 % | 23 % / 24 % | ran away (see below) |
| Korean with English words | 12 % / 23 % | 25 % / 37 % | 25 % / 37 % | 0 % / 0 % |
| English, Russian and Korean | 18 % / 7 % | 41 % / 48 % | 71 % / 86 % | 71 % / 75 % |

Qwen3-TTS samples differently on every run, so its numbers move from run to run: the same Korean
sentence scored 0 %, 19 % and 6 % in three runs.

Speed and size of Qwen3-TTS on the Mac:

| Measure | Value |
| --- | --- |
| Time until the first sound is available (streaming) | 0.08 to 0.13 s |
| Generation speed | about 5 times faster than real time |
| Loading the model | 8.6 s, then 3.8 s for the first sentence |
| Peak MLX memory during the runs | 5.5 GB |
| Download | 1.9 GB |

Apple's voices need no download and no model loading. Their start-up delay was not measured
here: the clips were rendered to files with the `say` command, which is not how the app plays
them.

## What it means

- **One language at a time, Qwen3-TTS is at least as intelligible as Apple's standard voices**,
  clearly more so in Korean, and it starts speaking fast enough for a conversation.
- **Mixed sentences are Qwen3-TTS's weak point.** Given one language, it reads foreign words
  with that language's sounds ("meeting" became "митинг"). Left to choose, it did worse.
  Split by writing system it is unsafe: asked to speak the single word "meeting", it produced
  eleven minutes of noise. Apple's voices, switched per script, were the most reliable here.
- **Memory is the obstacle on a phone.** 5.5 GB peak on the Mac is more than an iPhone app can
  be expected to get, before any speech recogniser is added (Rumble-2-Flash needs another 1.6
  to 1.9 GB; Apple's recognisers run outside the app's memory). A smaller
  quantization or shorter generation windows may lower it; neither was tried.
- **The voice is not fixed.** This checkpoint has no named speakers, so the voice can differ
  between sentences. A fixed voice needs a reference clip (voice cloning) or the CustomVoice
  checkpoint; neither was tried.

Recommendation at the time: keep Apple's voices as the default and treat Qwen3-TTS as a
candidate. It is superseded by the decision at the top of this file.

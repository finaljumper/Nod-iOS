# Benchmark methodology

This document defines what the app measures and how to run it so that two runs can be compared.

## The two modes

| | Batch | Streaming |
| --- | --- | --- |
| Audio delivery | Whole recording at once, as fast as the engine accepts it | 100 ms chunks at real-time speed |
| Question it answers | How fast and how accurate is the engine on a finished recording? | How soon does text appear while someone is speaking? |
| Latency metrics | Time to final transcript, real-time factor | First partial, first stable, final, end-of-speech to final |

Results of the two modes are stored and aggregated separately. A batch latency and a streaming
latency are never compared: a streaming run cannot finish before the audio does.

## Audio path

1. The file is decoded once into mono 32-bit float samples at its native rate. WAV is decoded by
   the project's own decoder, so the samples are identical on every device and OS version.
   Multichannel files are averaged to mono.
2. For each engine the samples are resampled to the rate the engine asks for, with one
   deterministic resampler (Kaiser-windowed sinc). Engines that ask for the same rate receive
   identical samples. An engine that needs 16-bit integers receives the rounded version.
3. A fingerprint (FNV-1a hash) of the decoded samples is stored with every run. Equal
   fingerprints across engines and runs show that the same audio was used.

Decoding time and resampling time are recorded separately and are not part of any inference
time.

## Run order

1. **Availability.** Each engine reports per language whether it can run. Combinations it cannot
   run are recorded once with status `unavailable` and a reason, and are not executed.
2. **Cold start** (optional). The engine is unloaded, then loaded with a timer running, and the
   first transcription after that load is recorded with phase `cold`.
3. **Warm-up.** One discarded transcription per engine and language (configurable).
4. **Measured runs.** Every recording, engine and language hint, at least three times.

Rules that hold throughout:

- Exactly one transcription runs at a time.
- With *interleaved* order every recording goes through all engines before the next recording,
  and the engine order within a recording is shuffled with a recorded seed. Slow drift such as
  heat build-up then affects all engines alike.
- With *engine blocks* one engine finishes the dataset before the next starts, and the other
  engines are unloaded meanwhile. Use this for per-engine memory and battery figures.
- Nothing is downloaded during a benchmark. Engines are loaded with downloads disabled.

## Run statuses

| Status | Meaning | Counted in error rates |
| --- | --- | --- |
| `success` | The engine returned a transcript | Yes |
| `unavailable` | The engine cannot run this language or capability on this device | No |
| `failed` | The engine ran and threw an error | No, counted separately |
| `skipped` | The recording could not be used, for example its audio is missing | No |
| `cancelled` | The benchmark was cancelled during this run | No |

## Language hints

| Hint mode | What the engine is told | Purpose |
| --- | --- | --- |
| `primary` | The first language listed for the recording | Best case: the language is known |
| `auto` | Nothing | Whisper detects the language. Apple has no detection, so these runs are `unavailable` for it |
| `alternates` | Each further language of a code-switched recording, one run each | Shows what a single-locale engine makes of the other language |

Aggregates are kept apart by hint role, so auto-detect results never mix with hinted ones.

## Accuracy

**Word error rate** is `(S + D + I) / N` on whitespace-separated words, where `S`, `D` and `I`
are substitutions, deletions and insertions from a minimum edit distance alignment and `N` is
the number of reference words. **Character error rate** is the same on characters (extended
grapheme clusters, so one Hangul syllable is one character) with whitespace removed.

When several alignments have the same minimum cost, the one with the most exact matches is
used. The error rate is unaffected; only the split between `S`, `D` and `I` depends on it.

Aggregated rates are pooled: total errors divided by total reference length across all measured
runs of the group. Long recordings therefore weigh more than short ones.

### Normalization

Both scores are always computed.

| Step | Conservative | Relaxed |
| --- | --- | --- |
| Unicode form | NFC | NFKC |
| Case | kept | lowercased |
| Punctuation and symbols | kept | replaced by a space, except `'` between letters and `.` `,` `:` between digits |
| Russian `ё` | kept | folded to `е` |
| Whitespace | collapsed | collapsed |

Neither mode rewrites numbers, transliterates between scripts or removes diacritics.
`3`, `three`, `три` and `셋` are four different words. Write reference transcripts in the form
you expect the assistant to receive, and keep that convention across the dataset.

**Korean.** Word boundaries in Korean are a matter of spacing convention and two spacings of
the same sentence are often both acceptable. WER penalizes them; CER does not. Use CER as the
primary metric for Korean and for recordings containing Korean.

### Further accuracy measures

- **By language**: aggregates per language combination (`en`, `ru`, `ko`, `en+ru`, ...).
- **Code-switched**: aggregates for recordings with more than one language.
- **By script**: for each run, word outcomes grouped by the script of the word (Latin, Cyrillic,
  Hangul). In a mixed recording this shows which language's words were lost.
- **Key-term recall**: the share of a recording's `keyTerms` (names, dates, numbers) that appear
  in the transcript as a contiguous word sequence after relaxed normalization. Korean terms
  also match with an attached particle.
- **Command accuracy**: for the `command` category, the share of runs whose relaxed-normalized
  transcript equals the reference exactly.

## Latency

All times are wall-clock seconds from one monotonic clock.

### Batch

| Metric | Start | End |
| --- | --- | --- |
| Decode time | File read begins | Canonical samples in memory |
| Preprocess time | Resampling begins | Engine-format audio in memory |
| Time to final transcript | The runner calls the engine with audio already in memory | The engine returns the final transcript |
| Real-time factor | | Time to final transcript divided by audio duration; below 1 is faster than real time |

### Streaming

`t0` is the replay start: the instant the first sample of the recording is "spoken". A chunk
covering seconds `[a, b)` of the recording is handed to the engine at `t0 + b`, when a
microphone would have finished capturing it. Event times are taken by the adapter when the
engine delivers a result.

| Metric | Start | End |
| --- | --- | --- |
| Time to first partial | `t0` | First hypothesis with any text |
| First partial after speech start | `t0` + start of speech | Same event |
| Time to first stable | `t0` | First hypothesis with committed text. If the engine commits nothing before the end, this equals time to final and is flagged |
| Time to final | `t0` | Final transcript |
| End of audio to final | Last chunk handed over and end of input signalled | Final transcript |
| End of speech to final | `t0` + end of speech | Final transcript |

"Committed" means: for Apple, results marked final; for WhisperKit, segments the re-decoding
loop has confirmed.

Start and end of speech come from the manifest when given, otherwise from an energy gate
(frames within 35 dB of the loudest frame). The source is recorded per run.

**What end-of-speech latency does not include.** The benchmark signals end of input at the end
of the file. It performs no endpoint detection, so the time an assistant spends deciding that
the speaker has finished is not measured. Trailing silence in a file adds to
end-of-speech-to-final for both engines equally.

**Replay lateness** is the largest delay between a chunk's scheduled and actual delivery. A run
with large lateness did not keep real-time pace and its latencies should not be trusted.

### Model preparation

Load time starts when the engine is asked to prepare and ends when it can accept audio.
Download time is reported separately and only occurs in the setup step.

Cold start has limits on both engines. Core ML keeps a specialization cache on disk that apps
cannot clear, and Apple's speech models are managed by the system. The first load after
launching the app is the coldest state the app can reach. For a comparable cold figure,
relaunch the app before each benchmark that measures it.

### Statistics

Median and 95th percentile use linear interpolation between ranks. With three repetitions the
95th percentile is `0.1 × middle + 0.9 × largest`, close to the maximum. Raise the repetition
count if tail latency matters.

## Resources

| Metric | How it is measured | Caveat |
| --- | --- | --- |
| Peak memory | Process memory footprint, sampled every 20 ms during the run | The app's process only. In interleaved order it includes every loaded engine |
| CPU | Process CPU time during the run divided by wall time | GPU and Neural Engine work is not CPU time |
| Thermal state | Before and after each run | Runs at `serious` or hotter are flagged; the runner waits up to two minutes for the device to cool first |
| Battery | Level at start and end of the run, and per engine in engine-block order | 1% resolution on iOS; meaningless while charging; unavailable on a Mac mini |
| Model storage | Size of the model folder | WhisperKit only; Apple's assets are system-managed |

For Apple's engine, confirm with Instruments that inference happens inside the app's process
before relying on its memory and CPU numbers.

## Running a comparable benchmark

1. Build the **Release** configuration (the scheme's Run action already uses it). Debug builds
   and the Simulator are flagged in the results.
2. Run the setup step once per device while online, then switch to airplane mode.
3. Quit other apps. On iPhone and iPad turn Low Power Mode off and keep the device unplugged
   and at room temperature. Start from a cool device.
4. Relaunch the app if cold start is being measured.
5. Run batch and streaming as two separate benchmarks.
6. Export JSON after every run. The JSON holds the device, OS, configuration, seed, engine
   descriptions, every transcript and every measurement.
7. Repeat the whole procedure on each target device. Results from different devices are
   separate data points.

## Reading the results for the engine decision

- Compare engines within one mode, one hint role and one normalization at a time.
- A language an engine reports as `unavailable` is a finding about coverage, not a zero.
- For code-switched recordings read CER and the by-script breakdown together.
- A thermally affected or late-replay run is a reason to rerun, not a data point.
- Whisper's streaming figures describe the simulated scheme with its settings (one second of
  new audio per decode, two unconfirmed segments). They are properties of that scheme as much
  as of the model.

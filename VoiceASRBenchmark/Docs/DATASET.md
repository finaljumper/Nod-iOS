# Dataset

The benchmark reads a folder with a `manifest.json` and the audio files it lists.

```
MyDataset/
├── manifest.json
└── audio/
    ├── en-conv-001.wav
    ├── en-conv-001.txt      (optional sidecar transcript, used by the scaffold tool)
    └── ...
```

The app ships one manifest, `App/Resources/Dataset/manifest.json`, with 20 sentences to record
and **no audio**. Every entry there shows as "audio file is missing" and is skipped. It exists
to show the schema and to serve as a recording script. It is not a benchmark dataset and no
results can come from it.

## Manifest schema

```json
{
  "schemaVersion": 1,
  "name": "Home recordings, November 2026",
  "description": "optional",
  "recordings": [
    {
      "id": "ru-en-cs-001",
      "audioFile": "audio/ru-en-cs-001.wav",
      "transcript": "Напомни мне про meeting с командой завтра в десять и скинь agenda в чат.",
      "languages": ["ru", "en"],
      "category": "conversational",
      "durationSeconds": 5.84,
      "speaker": "spk01",
      "tags": ["quiet-room"],
      "keyTerms": ["meeting", "agenda"],
      "speechStartSeconds": 0.31,
      "speechEndSeconds": 5.52,
      "source": "self-recorded"
    }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique within the manifest |
| `audioFile` | yes | Path relative to the manifest |
| `transcript` | yes | What was actually said, in the written form you want back |
| `languages` | yes | BCP 47 codes. The first is the primary language; more than one marks code-switching |
| `category` | yes | `conversational`, `command`, `long-form`, `entities` or `disfluent` |
| `speaker` | yes | Anonymous speaker identifier |
| `durationSeconds` | no | Checked against the file when present |
| `tags` | no | Difficulty tags; results can be grouped by tag |
| `keyTerms` | no | Names, dates, numbers and other terms scored separately |
| `speechStartSeconds`, `speechEndSeconds` | no | Speech bounds for streaming latency; estimated from signal energy when absent |
| `source` | no | Where the recording came from |

The categories and the language list are independent. An English–Korean short command is
`"languages": ["en", "ko"]` with `"category": "command"`.

| Brief requirement | How to express it |
| --- | --- |
| English, Russian or Korean only, conversational | one language, `conversational` |
| English–Russian, English–Korean, Russian–Korean, three-language code-switching | two or three languages, any category |
| Short commands | `command` |
| Long conversational sentences | `long-form` |
| Names, dates, numbers, calendar vocabulary | `entities`, with `keyTerms` |
| Hesitations, pauses, fillers | `disfluent` |

## Recording

- Real speakers, speaking naturally. Synthetic speech is not a substitute; if you add any, tag
  it `synthetic` so it can be excluded.
- Lossless files: WAV (PCM 16 or 24 bit, or float). Mono, 16 kHz or higher; 48 kHz is fine.
  Stereo is averaged to mono. Lossy formats are accepted with a warning.
- Record on the device class the assistant will listen on, at the distance it will be used.
- Leave about a third of a second of room tone before and after the speech.
- After recording, listen back and **edit the transcript to match what was said**, including
  fillers and false starts for the `disfluent` category. A reference that differs from the audio
  shows up as engine errors.
- Pick one written convention for numbers, dates and loanwords and keep it. The scoring does
  not treat `3` and `three` as equal.
- For code-switched sentences write each word in the script the speaker would expect to read:
  `meeting` in Latin script if that is how it should come back.
- Several speakers per language matter more than many sentences from one speaker.
- A sensible first target: 10 recordings per category and language combination, from at least
  three speakers.

Recordings of voices are personal data. `.gitignore` excludes a `Datasets/` folder; keep
recordings out of the repository unless every speaker agreed to that.

## Importing

1. Put the WAV files in `MyDataset/audio/`. Name them with a language prefix when you can
   (`en-…`, `ru-en-…`, `en-ru-ko-…`); the first language is the primary one. Optionally put the
   transcript next to each file as a `.txt` with the same name.
2. Create or extend the manifest:

```bash
swift run asrbench-dataset scaffold MyDataset --speaker spk01 --source self-recorded
```

   Every WAV not yet listed gets an entry with its duration, its transcript from the sidecar
   file, and languages from the file name or, failing that, from the scripts in the transcript.
3. Edit `manifest.json`: set `category`, add `keyTerms` and `tags`, fix the language order.
4. Check it:

```bash
swift run asrbench-dataset validate MyDataset
```

   Errors mean a recording cannot be used (missing file, empty transcript, below 16 kHz,
   duplicate id). Warnings are for attention (stereo, duration mismatch, lossy format).
5. Give the folder to the app:
   - **macOS**: Benchmark tab, *Import dataset folder…*. The folder is remembered.
   - **iPhone and iPad**: copy the folder into the app's Documents directory with Finder or
     the Files app (file sharing is enabled). Every folder there with a `manifest.json`
     appears in the dataset picker. *Import dataset folder…* works too.

`swift run asrbench-dataset durations MyDataset` rewrites every duration from the files.

## Existing corpora

Public read-speech corpora such as Mozilla Common Voice or Google FLEURS contain real speakers
in English, Russian and Korean and can fill the single-language categories quickly. Check each
corpus's licence before use, convert to WAV, and record the corpus name in `source`. They do not
cover code-switching between these three languages or assistant-style commands; those have to
be recorded.

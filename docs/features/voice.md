# Voice: hold the launcher shortcut to talk to the AI

Hold the toggle shortcut — the one that opens Smallcast — for half a second and the palette switches
to AI Chat and listens. Release it and what you said is transcribed on this Mac and asked, exactly as
if it had been typed in root search and sent with the AI chord. `Features/Voice/` holds the engine
catalog, the speech runners, the model downloader and the settings section; the hold itself is
recognised in `Features/HotKeys/` (see [hotkeys.md](hotkeys.md#hold-to-talk)).

## Invariants

- **A hold never slows a press.** The toggle fires on key-down exactly as before; the hold is decided
  by `HoldDetector` at `HoldDetector.threshold` (450 ms) while the palette is already up, and only a
  `.combo` binding can hold — a double-tap fires on its second *release*, so it has nothing to hold.
- **Off means fully off, twice.** A hold does nothing unless `AppSettings.aiEnabled` and
  `VoiceSettingsStore.holdToTalk` are both on, and the chosen engine's files are on disk. A hold with
  the engine missing says so in a HUD rather than downloading anything.
- **Every engine runs on this Mac.** No audio ever leaves it: Apple Speech is `SpeechAnalyzer`'s
  on-device module, and every other engine is a CoreML export loaded from
  `~/Library/Application Support/<bundle id>/voice-models/`. The only network traffic is the model
  download, on a private `.ephemeral`, `urlCache = nil` session, and only for the engine the user
  picked — nothing is fetched at launch or on a hold.
- **`Model/` is Foundation-only and pinned by `voice-test`**: the catalog's stored spellings, both
  tokenizers (`SentencePieceVocabulary` reads the JSON and the `.model` protobuf; `WhisperVocabulary`
  reads `tokenizer.json` and undoes GPT-2's byte-level BPE) and `TransducerDecoder`'s greedy loop. The
  CoreML calls live in `Service/`, where `voice-engine-test` runs every downloaded engine against a
  spoken fixture and skips, with a reason, on a Mac that has none.
- **The three settings stay out of backups.** `aiVoiceHoldToTalk` arms the microphone,
  `aiVoiceEngine` names a download from Hugging Face, and `aiVoiceLanguage` only paces the engine
  choice; `SettingsBackupCoverage` gives each its reason.
- **Speech reaches the AI through `AIChatCoordinator.ask`**, the same call the AI chord and the
  fallback row make, so a spoken question and a typed one cannot behave differently. Escape while
  the engine is still transcribing means never mind: the text is dropped rather than asked behind
  the reader's back (`paletteCoordinator.isVisible` is the check).

## The engines

The catalog is `VoiceEngine`; every case carries its title, a tagline, strengths, weaknesses, its
language coverage, the download size and the Hugging Face files it needs. The settings card shows
all of it, the way FluidVoice presents its engine list.

| Engine | Runs as | Download | Languages | Note |
| --- | --- | --- | --- | --- |
| Speech 3.5 — Ultra Fast Low Latency | streaming Nemotron RNNT, `MLState` encoder | 700 MB | ~40, auto-detected | NVIDIA Nemotron 3.5, int8 |
| Speech 3.5 — Multilingual | batch Nemotron RNNT | 556 MB | ~40, auto-detected | slower, more accurate |
| Parakeet Flash (Beta) | streaming Parakeet EOU RNNT | 225 MB | English | 120M, fed half a window per hop |
| Parakeet TDT v3 | batch Parakeet TDT | 632 MB | 25 European | the FluidVoice default |
| Parakeet TDT v2 | batch Parakeet TDT | 464 MB | English | best English of the family |
| Cohere Transcribe | Conformer encoder + cached transformer decoder | 2.2 GB | 14, told | ~20 s per question: the encoder always sees 35 s |
| Apple Speech | `SpeechAnalyzer` + `SpeechTranscriber` | none | system | assets install on first use of a language |
| Whisper Tiny … Large | WhisperKit CoreML export | 77 MB – 1.5 GB | 99, auto-detected | Large is `large-v3`, 947 MB quantised |

"Speech 3.5" is what FluidVoice calls NVIDIA's Nemotron 3.5 ASR pair; the two are separate models
with separate downloads. Nothing here is a cloud service and no engine takes an API key.

### Runners

- `TransducerTranscriber` — Parakeet v2/v3 and the batch Nemotron. Preprocessor → encoder →
  `TransducerDecoder` over `CoreMLTransducerNetwork`. Parakeet's joint answers a duration bin that
  skips frames; the Nemotron joint has none, so its `durationBins` is `[0]` and the loop stays on a
  frame until it hears a blank, which is plain RNNT. Audio past the 15 s export window is cut into
  windows with the LSTM state and last token carried across. The Nemotron encoder takes a one-hot
  `prompt_vector` built from `metadata.json`'s prompt table; `auto` is prompt 101.
- `StreamingTransducerTranscriber` — Parakeet Flash and the streaming Nemotron. Flash's exported
  preprocessor is run per hop (it normalises nothing, so hops are independent) and the encoder is fed
  a 17-frame window every 8 frames, carrying `pre_cache` and both caches; it produced only blanks when
  fed whole windows, which is the overlap FluidAudio also uses. Its end-of-utterance token (1024) is
  skipped rather than obeyed: a hold already knows where the utterance ends. The Nemotron encoder is
  stateful (`encoder.makeState()`), sees a 73-frame window advanced by the 32-frame shift its metadata
  names, and gets two hops of silence at the end so its lagging output closes the last word.
- `WhisperTranscriber` — mel → encoder → the external-KV-cache decoder, one token per prediction, the
  reference loop from WhisperKit's export. Language `auto` runs one decoder step on
  `<|startoftranscript|>` with the answer restricted to language tokens. **The decoder runs on
  `.cpuAndGPU`**: on the Neural Engine its cache reads back wrong and every word comes out three times.
- `CohereTranscriber` — the front end is computed here (`CohereMelSpectrogram`, the NeMo log-mel
  with per-band CMVN, on `Accelerate`), because the export ships none; then a fixed 3 500-frame
  encoder and the `_v2` static-mask decoder with the reference prompt, repetition penalty and
  three-gram block. The encoder's cost is fixed per window, so every question costs ~20 s.
- `AppleSpeechTranscriber` — installs the locale's assets if needed, feeds the whole recording as one
  `AnalyzerInput` and joins the final results. `SpeechAnalyzer` sends nothing to Apple, so it needs no
  speech-recognition usage string — only the microphone one.

### Capture

`VoiceRecorder` is an `AVCaptureSession` with an `AVCaptureAudioDataOutput` asked for 16 kHz mono
Float32, so the capture pipeline resamples and every engine gets the one format it takes. It is
`AVCapture` rather than `AVAudioEngine` because the engine's `connect` and `installTap` are deprecated
on the current SDK. Samples cross from the capture queue under one lock; `stop()` drains them.

### Loading

`VoiceCoordinator` keeps one loaded engine. A load is followed by one silent second so CoreML
specialises the graphs then rather than on the first real question — the first prediction otherwise
costs several seconds on the Nemotron exports. `warmUp()` runs at launch and when the engine changes.

## Settings

Settings → AI → Voice: the hold switch, the engine row with its download state and a `Choose…` sheet
of cards, and the language. Automatic is the default and the engines that detect a language use it;
Cohere refuses to guess and asks for one; the English-only Parakeets ignore it. `VoiceModelStore`
downloads by listing each bundle through the Hugging Face tree API and streaming every file; a
`.mlpackage` is compiled once into a `compiled/` sibling. Removing an engine keeps a file another
installed engine also lists.

## Manual sweep

- Hold the toggle shortcut with AI on: the palette opens on its first frame, switches to a level
  meter at half a second, and the meter moves with your voice. Release: a spinner-free
  "Transcribing…", then the question is sent as a new chat.
- Tap the shortcut as before: it toggles with no added delay.
- Hold with AI off, or with the switch off: nothing but the toggle.
- Hold with an engine not downloaded: a HUD names it and nothing is fetched.
- Escape while transcribing: nothing is asked.
- Settings → AI → Voice → Choose…: each card shows strengths, weaknesses, languages and size;
  Download shows progress and the row's subtitle follows; Remove frees the files.
- Harnesses: `voice-test` (catalog, tokenizers, decode loop), `voice-engine-test` (every downloaded
  engine on `SMALLCAST_VOICE_FIXTURES="path=expected text=lang;…"`), `hotkey-test` (`HoldDetector`).

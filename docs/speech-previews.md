# On-device speech previews

Worklog can transcribe on this iPhone itself, with no network and no account.
It runs whenever recording runs, and produces two things: a live provisional
line for the dictation bubble, and finalized, time-stamped words stored in
the database.

Those words do two jobs:

- **Navigation.** Clip range selection shows the first and last few words of
  the chosen span, and the transcript picker lets a range be chosen from the
  text itself rather than from a waveform.
- **Transcription.** Whenever Scribe hasn't produced a transcript - switched
  off, no API key, failed, or still running - the on-device words *are* the
  transcript, labelled with their provenance. Someone who never links a
  Scribe account still gets a working app.

When Scribe does produce a transcript, the on-device words stay beside it
permanently, collapsed, rather than being discarded.

## Architecture

`PreviewTranscriber` is the seam: `availability()`, `prepareAssets()`,
`start(onEvent:)`, `feed(buffer:at:)`, `finish()`. `SpeechPreviewEngine` owns
the lifecycle, gated on `RecordingController.state == .recording`, and takes
its audio from `LiveAudioTap` - the same buffers the recording is made of, so
previews describe exactly what was recorded rather than a second microphone
stream.

**The recognizer is never allowed to open the microphone.** On iOS this is a
choice rather than a hard constraint, and it is still the right one: a second
capturer competing for the input is a way for the recording - the thing the
app exists to protect - to end up degraded or silent. Both engines accept
app-provided buffers, so neither ever needs to.

On Android the same rule is not a preference but a requirement: the platform
hands real microphone input to exactly one capturer, the recognition service
outranks an app, and a recognizer left to listen on its own silences Worklog's
own recording to digital zero. See `docs/speech-previews.md` in
`worklog-android` for how that is worked around there.

## Two engines

`SpeechPreviewEngine.makeTranscriber()` picks the best one the device can run.
Nothing else in the app knows which engine produced a word beyond the `id`
string stored beside it.

### `AppleSpeechPreviewTranscriber` - iOS 26+

`SpeechAnalyzer` + `SpeechTranscriber`, shared verbatim with the macOS build.
Reports genuine per-word timings, which is what makes a preview word land on
the right second of a clip, and its locales can be downloaded on demand from
Settings.

#### Never supply an explicit buffer timestamp

`AnalyzerInput(buffer:bufferStartTime:)` fails with
`SFSpeechErrorDomain Code=2 - "Audio input timestamp overlaps or precedes
prior audio input"`. Format conversion pads buffers, so consecutive buffers
overlap nominally even though the audio doesn't.

The fix is `AnalyzerInput(buffer:)` with no timestamp at all, plus a
per-session wall-clock anchor: the moment the session's first buffer was
captured. Result times arrive relative to the session, and anchor + offset
gives a real point in the recording. Sessions rotate on a long gap or on age,
and each rotation re-anchors.

#### Reporting options

`.volatileResults` gives the live provisional tail for the dictation bubble;
`.audioTimeRange` gives per-word ranges. Finalized results arrive with
`isFinal == true` and are split per run into words.

### `LegacySpeechPreviewTranscriber` - iOS 17 to 25

`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Two things
about it need working around, and both are worked around rather than papered
over:

- **Timings are per segment, not per word.** A segment is usually one word but
  can be a short phrase, so each segment's words are spread across its window
  in proportion to their length. Approximate, and fine: the window itself is
  real, so a word still lands within about a second of where it was said. The
  Android build makes exactly the same compromise for its ML Kit engine.

- **A recognition task has a hard length limit** - around a minute in
  practice, after which it simply stops. An all-day recorder cannot live with
  that, so tasks are rotated on age (45s) and on any real gap in the audio,
  with each new task re-anchored to the wall clock of its first buffer.

`supportsOnDeviceRecognition` is checked before use and treated as
disqualifying. Without an installed offline model this recognizer silently
falls back to Apple's servers, and sending a day of audio to a server is
precisely what this feature exists to avoid.

## Storage

`preview_words` holds the free-floating timeline - one row per word, on the
same wall clock as segments - and is pruned on the raw-audio retention
window, because it describes audio that no longer exists. It is device-local:
never exported, never in clip archives.

`clip_preview_words` and `dictation_preview_words` are the permanent copies,
snapshotted at creation with a foreign key to their owner and **never
pruned**. They are copied rather than referenced by time range for exactly
that reason: a clip pointing at `preview_words` would lose its transcript on
the first retention sweep past it. The snapshots travel with a clip through
export and import, as `previewWords` in the archive manifest; the rolling
table never leaves the device.

The cascade on delete is written out by hand in `deleteClip` /
`deleteDictation`. The schema declares `ON DELETE CASCADE`, but this database
runs with SQLite's default `foreign_keys = OFF` - several older tables carry
`REFERENCES` that predate any enforcement, and turning it on globally could
start rejecting writes that work today.

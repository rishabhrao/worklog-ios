# Worklog Clip Archive Format - v1

The portable form of one Library clip: a plain ZIP that both apps (macOS and
Android) write and read. It exists so a clip - audio plus everything derived
from it - can move between a user's own devices, or to another Worklog user,
and land as a first-class Library clip on arrival. The zip is also deliberately
human-readable: someone without Worklog can unzip it and get the audio, the
transcript and the summaries as ordinary files.

File name written by exporters: `<display name, sanitized>.worklog.zip`.
Readers never rely on the file name - only on the contents.

## Container

A standard ZIP with **flat entries** (no directories). Any standard
compression method is legal per entry; readers must accept both `stored` and
`deflate`. Writers use these entry names; readers resolve entries **only via
the manifest's `file` references**, never by assuming names:

| entry | contents |
| --- | --- |
| `manifest.json` | UTF-8 JSON, described below. Required. |
| `audio.m4a` | The clip audio, AAC in an MPEG-4 container - byte-identical to the library copy. Required. |
| `transcript.json` | Verbatim speech-to-text provider response, exactly as stored in the clip folder. Present only when transcription succeeded. |
| `transcript.txt` | The transcript rendered as plain text (same rendering the detail screens show). Informational, for humans; importers ignore it. |
| `translation-<language>.md` | One per completed translation. |
| `summary-<preset>.md` | One per completed summary, always suffixed - the overview is `summary-overview.md` here even though it's stored as `summary.md` locally. |

## manifest.json

```json
{
  "format": "worklog-clip",
  "version": 1,
  "exportedAtMillis": 1754388000000,
  "exportedAt": "2026-08-05T14:00:00+05:30",
  "exportedBy": "worklog-android",
  "clip": {
    "id": "8D9A2F60-…",
    "defaultName": "Clip 2026-08-05 2:00 PM",
    "displayName": "Standup notes",
    "createdAtMillis": 1754388000000,
    "sourceStartMillis": 1754380800000,
    "sourceEndMillis": 1754384400000,
    "durationSeconds": 3600.0,
    "audioFile": "audio.m4a",
    "deviceUid": "…",
    "location": { "latitude": 12.97, "longitude": 77.59 }
  },
  "transcript": {
    "id": "5C7E…",
    "file": "transcript.json",
    "textFile": "transcript.txt",
    "provider": "elevenlabs",
    "model": "scribe_v1",
    "speakerCount": 2,
    "cost": { "usd": 0.264, "source": "estimated", "billedSeconds": 3600.0 }
  },
  "translations": [
    {
      "language": "hinglish",
      "file": "translation-hinglish.md",
      "provider": "…", "model": "…",
      "cost": { "usd": 0.01, "source": "reported", "inputTokens": 9000, "outputTokens": 8000 }
    }
  ],
  "summaries": [
    {
      "preset": "overview",
      "file": "summary-overview.md",
      "translationLanguage": null,
      "provider": "…", "model": "…",
      "cost": { "usd": 0.004, "source": "reported", "inputTokens": 9000, "outputTokens": 400 }
    }
  ],
  "tags": [
    { "name": "video editor", "color": "moss", "source": "auto" },
    { "name": "hiring", "source": "manual" }
  ]
}
```

Field rules:

- `format` must be `"worklog-clip"` and `version` must be `1`. Readers reject a
  larger `version` with a clear "export from a newer Worklog" error rather
  than guessing.
- Unknown fields are ignored everywhere (forward compatibility).
- All timestamps are **epoch milliseconds** (`…Millis`, integers) - those are
  authoritative. `exportedAt` is an ISO-8601 rendering for human readers of
  the manifest; importers never parse it.
- `transcript` is `null` (or absent) when the clip has no completed
  transcript. `translations` / `summaries` list **succeeded** steps only -
  pending or failed rows are not exported.
- `summaries[].translationLanguage` names the translation a summary was
  derived from; `null` means it came from the raw transcript.
- Cost objects mirror the row provenance: `source` is `"reported"` or
  `"estimated"`; members that don't apply are omitted or `null`.
- File references (`audioFile`, `file`) must be **plain names** - no path
  separators, no `..`. Importers reject anything else.
- `tags` is optional and carries a clip's tags **by name**, lowercase. Tag ids
  are local rows and are deliberately not in the archive. `color` is one of the
  palette keys (`slate`, `rust`, `amber`, `moss`, `teal`, `indigo`, `plum`) and
  is only a *hint*; it is omitted for a tag that never had one set explicitly.
  `source` is `"manual"` or `"auto"`.
- Adding `tags` did **not** bump `version`, on purpose. Readers reject a
  manifest newer than they understand, so bumping for a purely additive field
  would make every already-installed build refuse files it can read perfectly
  well. Old readers ignore the key; new readers pick it up.

## What is deliberately *not* in the archive

- **The place.** Only `clip.location`'s raw coordinates travel. A place name is
  a fact about whose library the clip is sitting in, not about the recording,
  so the importer resolves it from *their* places every time it is displayed -
  a clip recorded at someone else's "Office" shows up under whatever you call
  that spot, or under the OS-detected name if you have never named it. Shrink
  or rename a place later and every imported clip re-labels with it, exactly
  like a locally recorded one.
- **Tag ids and the tag vocabulary.** Only the tags actually on this clip
  travel, and only by name - importing a clip never drags in the exporter's
  whole tag list.

## Import semantics

- **Identity is preserved.** The imported clip keeps `clip.id`, so moving a
  clip between your own devices is stable. If a clip with the same id already
  exists locally, the import is skipped and reported as "already in your
  library" - it is never silently duplicated.
- The transcript row keeps `transcript.id` (transcripts are found by
  `clip_id`, so any string id is safe). Translation and summary row ids are
  **re-derived by the importer** using its local conventions
  (`<transcriptId>-<language>`, `<transcriptId>-summary[-<preset>]`), because
  those ids are derived at lookup time, not stored references.
- Files land under the importer's own clip-folder conventions
  (`clips/<id>/audio.m4a`, `transcript.json`, `translation-<language>.md`,
  `summary.md` for the overview, `summary-<preset>.md` otherwise) regardless
  of what they were called in the archive.
- Rows for imported artifacts are written as `succeeded` with the provider /
  model / cost provenance carried in the manifest.
- A summary whose `preset` the importing app doesn't recognize is skipped -
  never coerced onto a known preset.
- **Tags merge into the local vocabulary.** Each `tags[]` entry is matched to
  an existing tag with the same name (case-insensitively) and reused, or
  created when genuinely new. A tag that already exists locally **keeps its own
  colour** - the manifest's `color` applies only to tags the importer has to
  create. `source` is preserved, so re-running tagging on the importing side
  replaces exactly what it would have replaced on the exporting side instead of
  piling new auto-tags on top of old ones.
- Whatever the archive did **not** contain proceeds locally: importing a clip
  without a transcript queues transcription; one with a transcript but no
  summaries produces the summaries the local settings ask for. An import with
  everything present runs nothing and costs nothing.
- Extraction must guard against zip-slip: entries are consumed only via the
  validated manifest references, and no entry may be written outside the
  extraction directory.

## Raw audio import

The same import entry point also accepts bare audio files (m4a, mp3, wav, and
whatever else the platform decoder handles). Dispatch is by content, not file
extension: bytes beginning `PK\x03\x04` are treated as a zip (and must contain
a valid manifest); anything else is handed to the audio importer.

A bare audio file becomes a **new** clip (fresh UUID):

- Audio is normalized into the library's canonical form - AAC in `.m4a`. A
  source that is already AAC in an MPEG-4 container is copied byte-for-byte;
  anything else is transcoded on device.
- `displayName` / `defaultName` come from the source file name (extension
  stripped).
- `createdAt` is the import time. `sourceStart`/`sourceEnd` are best-effort
  recording times: `fileModified − duration … fileModified` when the file's
  modification time is plausible, else `import − duration … import`.
- Transcription (and everything downstream) is queued exactly as for a
  freshly recorded clip.

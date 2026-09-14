# The probe contract

`ytdl <url> --probe` prints one JSON document on stdout and exits. This file
is the full description of that document.

**It is a contract, not a description of an implementation.** Four programs
in three other repositories read it, none of which this repo knows exists,
and none of which will fail loudly if a field quietly changes meaning — the
symptom is a Quality menu offering a resolution the video does not have, or a
container the merge cannot produce, with no error anywhere. That is the same
class of failure `docs/archive-layout.md` exists to prevent, and it is
managed the same way: a version number in the payload, and a rule about when
it moves.

## Versioning

`probe_version` is the first field emitted. It is currently **1**.

**Bump it when a change would make an existing reader wrong** — a field
removed, renamed, or given a different meaning; a value's units changed; an
array's ordering rule changed. **Adding a field is backward-compatible and
needs no bump**, which is the same rule the archive layout uses, for the same
reason: a reader that does not know a field ignores it.

A consumer that reads a `probe_version` it does not recognise should say so
rather than guess. It is the first field precisely so that decision can be
made before anything else is parsed.

## The output rule

**One JSON document on stdout, or nothing on stdout.**

Success is exit 0 with a parseable document. Failure is a non-zero exit, a
message on stderr, and stdout empty. Everything conversational — the
"Probing ..." note, every PO token line, every warning — goes to stderr on
purpose, so a consumer can decide whether the probe worked by trying to parse
stdout and needs no other signal.

This is the single easiest thing to break by accident. A `Write-Host` added
to `probe.ps1` for debugging, left in, turns every frontend's preview into a
parse error simultaneously while a human running the command notices nothing
at all. `085-probe` asserts it.

## Top-level fields

Always present:

| Field | Type | Notes |
|---|---|---|
| `probe_version` | int | See above. First field emitted. |
| `probed_at` | string | ISO 8601, UTC. |
| `url` | string | The URL exactly as it was given. |
| `kind` | string | `video` or `playlist`. A channel is a `playlist`. |
| `id` | string | Video id, or playlist id. |
| `title` | string | |
| `uploader` | string | Falls back to `channel` when yt-dlp gives no uploader. |
| `entry_count` | int | `1` for a video; the number of entries emitted for a playlist. |
| `entries` | array | Empty for a video. See below. |
| `entries_truncated` | bool | See "Truncation". |
| `pot` | object | `healthy`, `reason`, `note`. See below. |

Present for `kind: "video"`:

`channel`, `channel_url`, `extractor`, `duration` (seconds, float),
`upload_date` (`YYYYMMDD`), `view_count`, `like_count`, `comment_count`,
`live_status`, `availability`, `age_limit`, `thumbnail`, `description`,
`webpage_url`, `subtitle_langs`, `automatic_caption_langs`.

Present for `kind: "playlist"`:

`channel`, `extractor`, `playlist_count` (what the extractor says the whole
list holds, which may exceed `entry_count`), `items_requested` (the `--items`
value, or empty), and — when the format table could be read — `duration`,
`thumbnail`, `formats_from_id` and `formats_from_title`.

Any of these may be absent, empty or null. yt-dlp's info dict varies by
extractor, by video and by version, and a consumer that requires a field to
be present will eventually meet a video that does not have it.

## The format table

`formats` is an array, one entry per real rendition. Storyboards (yt-dlp's
`.mhtml` pseudo-formats) are removed, as is anything carrying neither a video
nor an audio stream.

| Field | Notes |
|---|---|
| `format_id`, `ext` | yt-dlp's own. |
| `vcodec`, `acodec` | yt-dlp's own spellings, verbatim. `"none"` where absent. |
| `video_family` | `avc1`, `vp9`, `av01`, or **null**. |
| `audio_family` | `opus`, `aac`, `mp3`, `flac`, or **null**. |
| `height`, `width`, `fps`, `tbr` | Null where unknown. |
| `filesize` | Exact, and usually absent. |
| `filesize_approx` | yt-dlp's estimate. Kept separate on purpose. |
| `dynamic_range`, `format_note` | yt-dlp's own. |

`filesize` and `filesize_approx` are deliberately **not** collapsed into one
number. A frontend should be able to show "421 MB" differently from "~421
MB"; merging them presents a guess as a fact.

### The two families, and why they are not the same question

`video_family` and `audio_family` map yt-dlp's spellings onto **this
pipeline's `--codec` and `--audio-codec` vocabulary**, and the mapping is the
main reason this document exists:

- `avc1…` or `h264…` → `avc1`
- `vp09…` or `vp9…` → `vp9` (yt-dlp emits `vp09`; `vp9` alone is not enough)
- `av01…` → `av01` (spelled with a **zero**; yt-dlp never emits `av1`)
- `opus…` → `opus`; `mp4a…` or `aac…` → `aac`; `mp3…` → `mp3`; `flac…` → `flac`

A codec this pipeline has no flag for — VP8, for instance — maps to **null**,
not to `any`. `any` is a choice the user makes; reporting it for a rendition
whose codec has no spelling would be a lie about what was asked for.

That is why "does this format carry video" and "which `--codec` value does it
correspond to" are answered separately. A VP8 rendition has a real height the
user can legitimately ask for and no `--codec` spelling at all, so the height
lists below are built from the first question and the codec lists from the
second.

## The derived lists

These exist so that three frontends with no shared code do not each invent
them. A frontend rebuilding a dropdown should read these rather than scan
`formats` itself.

**`heights`** — distinct heights over every rendition carrying a video
stream, **descending**. `best` is deliberately not in this array: it is a
pipeline concept, always available, and belongs at the top of a frontend's
list unconditionally.

**`video_codecs`**, **`audio_codecs`** — the families actually offered, in
**canonical order** (`avc1, vp9, av01` and `opus, aac, mp3, flac`), not offer
order. yt-dlp's format ordering varies with client and with its own sorting
changes, and a dropdown whose entries reshuffle between two probes of the
same video looks broken.

**`containers`** — the `--container` values a merge could actually produce:

- `mkv` is always present. Matroska carries every codec pair YouTube serves,
  which is why it is this pipeline's default and its archival choice.
- `mp4` only when there is an `avc1` or `av01` video rendition **and** an
  `aac` audio rendition.
- `webm` only when there is a `vp9` or `av01` video rendition **and** an
  `opus` audio rendition.

These two are real constraints, not preferences. yt-dlp cannot mux Opus into
mp4 or AAC into webm; asking it to produces a re-encode or a failed merge
depending on version.

**`has_video`**, **`has_audio`** — booleans.

## Playlists

`entries` holds one object per entry: `index`, `id`, `title`, `duration`,
`uploader`, `url`, `thumbnail`.

**`index` is the 1-based position in the playlist, and it is the only number
that may be written back into `--items`.** It is emitted explicitly rather
than left to array position because a frontend that sorts or filters the list
would otherwise silently renumber it and queue the wrong videos — a bug whose
first symptom is the wrong download finishing successfully.

### Truncation

Enumeration is capped (500 by default) unless `--items` was given, in which
case the user's range governs and the cap does not apply. When the cap bites,
the list is cut and `entries_truncated` is `true`. A frontend must show that:
a silently short list of a 4,000-upload channel reads as a complete one.

### Where the format table comes from

A playlist probe reports the formats of its **first entry**, and names it in
`formats_from_id` / `formats_from_title`.

This is an approximation and the field name says so rather than hiding it. A
channel can serve 4K AV1 for a recent upload and 360p AVC for one from 2011.
Extracting every entry is what would make a preview cost more than the
download it precedes — a full `yt-dlp -J` over a large channel is tens of
minutes and hundreds of megabytes of JSON — so the probe makes two bounded
calls regardless of list size, and a frontend should say "formats shown are
for &lt;title&gt;" rather than presenting them as the playlist's.

## PO tokens

```json
"pot": { "healthy": true, "reason": "...", "note": "..." }
```

The probe brings up the same provider a real session does, because the player
clients it enables change which formats yt-dlp can see at all — a probe on
default clients can report a thinner table than the download will get, which
would make the preview wrong in the one direction a preview must not be.

One difference from a real run: **a probe never installs or updates the
provider**. `--skip-pot-update` is always in effect. A question must not have
an installation as a side effect.

When `healthy` is false the formats may be incomplete, and `note` says so in
a sentence a frontend can show verbatim.

## Failure

Non-zero exit, nothing on stdout, one `ERROR:` line on stderr carrying
yt-dlp's **last** stderr line — which is nearly always the useful one
("Video unavailable", "Sign in to confirm your age") with retry noise above
it.

## Consumers

Every out-of-repo consumer of this contract keeps its own fixture test
against a canned format list, the same obligation `docs/archive-layout.md`
places on readers of the archive. On this side, `085-probe` asserts the
derivation, the output rule, the refusals, and that a probe writes nothing
into the archive.

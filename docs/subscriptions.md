# Subscriptions and scheduled checks

`ytdl` can keep a list of sources and download what is new in them on a
timer, so a channel stays archived without anybody re-typing
`ytdl <url> --sync` by hand. This document is both the user guide and the
contract a frontend reads — the JSON document at the end is what a
frontend built on this pipeline parses.

Everything here lives in `scripts/subscriptions.ps1`, started by
`scripts/ytdl.ps1` (the only argument parser) the way `probe.ps1` and
`run_ytdlp.ps1` are.

---

## Quick start

```bash
# Subscribe: validated like a download, stored instead of run
ytdl "https://www.youtube.com/@SomeChannel/videos" --sync --quality 1080 --subscribe

# Turn on the hourly check (once per machine)
ytdl --schedule install

# See what is subscribed, when each was last checked, and when it is next due
ytdl --subscriptions

# Check now instead of waiting
ytdl --run-subscriptions all
```

---

## Subscribing

```
ytdl <url> [download options] --subscribe [--every Nh|Nd] [--name TEXT] [--paused]
```

Every download option is accepted and is validated **exactly as it would be
for a download** — `--codec av1` is refused with the same message either way
— and then stored instead of run. Each check hands the stored options back
to `ytdl.ps1`, so they are validated again every time; a subscription can
never hold an option a run would refuse, and one that an updated pipeline no
longer accepts fails its check visibly rather than being quietly ignored.

What is stored is the command line **as parsed**, not as typed:

| Typed | Stored |
|---|---|
| `--no-audio` / `--no-video` | `--mode video-only` / `--mode audio-only` |
| `--cookies cookies.txt` (relative) | the absolute path |
| `--path archive` or a positional path | `data_root`, an absolute path, apart from the options |
| `--audio-codec opus` without `--mode audio-only` | nothing (the warning drops it for a download too) |

Absolute paths matter because the schedule runs with whatever working
directory the operating system gives it.

| Option | Meaning |
|---|---|
| `--every N` | `Nh` or `Nd`, 1 hour to 30 days. Default **24h**. Whole hours, because the schedule checks hourly. |
| `--name TEXT` | A label shown instead of the URL. One line, up to 120 characters. |
| `--paused` | Store it without checking it until resumed. |

**Use `--sync` for a channel's `/videos` page.** That listing is newest
first, and `--sync` stops each check at the first video already archived.
Without it every check walks the whole listing — correct, because the
download archive still skips what you have, but slow on a large channel.
`ytdl` says so when you subscribe without it.

**Subscribing the same URL into the same data root again replaces its
options**, keeping its id, its interval (unless `--every` is given again) and
its history. That is how a subscription's download options are changed. The
same URL into a *different* data root is a second subscription — a channel
archived in full to one disk and audio-only to another is two subscriptions.

Refused with `--subscribe`:

- `--probe` — a probe downloads nothing, so there is nothing to repeat.
- `--refresh` — it re-fetches into videos that are already archived, and as
  a subscription would do that to every video in the listing on every check.

### Connection options are stored too

`--cookies`, `--cookies-from-browser`, `--proxy`, `--limit-rate` and
`--downloader` are stored with the subscription, because a scheduled check of
a members-only playlist needs its cookies as much as the first download did.
A proxy password is therefore in `configs/subscriptions.json` in plain text;
the file is created `chmod 600`, and every listing masks the password as
`***@`. See `SECURITY.md`, finding 7.

A frontend that keeps connection settings of its own sends them with
`--subscribe`, so a subscription uses the settings that were current when it
was saved; saving it again updates them.

---

## Managing subscriptions

These take no URL, and come **first** on the command line.

| Command | Does |
|---|---|
| `ytdl --subscriptions [--json]` | List them. `--json` prints the document below. |
| `ytdl --unsubscribe ID` | Stop checking it. Nothing it archived is touched. |
| `ytdl --edit-subscription ID [--every N] [--name TEXT] [--pause\|--resume]` | Change the interval, the label, or pause it. Never the download options — `--subscribe` the URL again for those. |
| `ytdl --run-subscriptions` | Check the ones that are **due**, deferring everything if another download is running. This is what the schedule runs. |
| `ytdl --run-subscriptions all` | Check every enabled subscription now. |
| `ytdl --run-subscriptions ID [ID ...]` | Check those now, **even if paused** — naming one is a stronger statement than having paused it. |
| `ytdl --schedule install\|remove\|status [--json] [--dry-run]` | The hourly check; see below. |

`ID` is the eight-character id from the listing. A URL is accepted instead
when exactly one subscription has it.

### When a subscription is due

Due when it has never been checked, or when

```
now >= last_run.started + every_hours - 30 minutes
```

The 30 minutes is half the hourly heartbeat. The heartbeat fires on the hour
with up to five minutes of random delay; without the slack a subscription
last started at 03:04 would not be due at 03:02 the next day, would run at
04:02 instead, and would drift an hour later every day.

A paused subscription is never due. A check that was cancelled (its process
killed) records nothing, so it is still due and runs at the next heartbeat.

### What a check does

For each subscription, in turn, longest-waiting first:

1. **Due-only runs:** if any `ytdl` download session is running — from a
   terminal, from an app's queue — stop, and leave this and every remaining
   subscription due for the next heartbeat. See *Concurrency*.
2. Run `ytdl <url> [--path <data_root>] <options...>` as its own process,
   with its session log set to `download.subscriptions.log`.
3. Pass every line of its output through unchanged, so a frontend running
   `--run-subscriptions` in its queue sees an ordinary session.
4. Record the result in the subscription's `last_run`.

The runner's own lines start with `[subscriptions]`.

| Result | Means |
|---|---|
| `ok` | The session exited 0 and its summary counted no `ERROR:` lines. |
| `errors` | The session exited 0, but some videos could not be fetched. Worth seeing, not a failure. |
| `failed` | The session exited non-zero — typically a stored option the pipeline now refuses. `message` holds its last line. |

Exit codes of `--run-subscriptions`: **0** when every check ran (or nothing
was due, or everything was deferred), **1** when any check failed, **3**
when another `--run-subscriptions` is already running, which is refused at
once rather than queued.

### Logs

| File | Written by |
|---|---|
| `<data root>/Archive Logs/Logs/download.subscriptions.log` | Every session a check starts, in that subscription's data root. **Not** `download.log`: `postprocess.ps1` slices each video's `video_complete.log` from its session log's most recent start marker, and a scheduled session interleaving with a manual one in the same file would hand the manual session's videos the wrong slice. |
| `<install root>/Archive Logs/Logs/subscriptions.log` | One line per check and per deferral. |
| `<install root>/Archive Logs/Logs/subscriptions.launchd.err.log` | macOS only: pwsh's stderr when launchd starts it, which is where a failure to start at all would appear. |

`Archive Logs/` is outside the archive layout contract
(`docs/archive-layout.md`), so none of this is a layout change.

---

## The schedule

```
ytdl --schedule install [--dry-run]
ytdl --schedule remove  [--dry-run]
ytdl --schedule status  [--json]
```

`install` registers **one hourly job** with the operating system, and that
job runs `ytdl --run-subscriptions`. The job is the same text for everyone
and never changes: each subscription's interval is data in
`configs/subscriptions.json`, so adding, pausing or re-timing a subscription
never touches the operating system. `--dry-run` prints what would be written
and run, and does neither.

Setup does **not** install the schedule. Registering a background job is a
deliberate step, and setup can be run non-interactively by another
program's installer, where nobody would see it happen.

| | Linux | macOS | Windows |
|---|---|---|---|
| Mechanism | systemd user timer | launchd agent | Task Scheduler task |
| Written to | `~/.config/systemd/user/ytdl-subscriptions.{service,timer}` (honours `XDG_CONFIG_HOME`) | `~/Library/LaunchAgents/io.github.avimehandru.ytdl-subscriptions.plist` | `\ytdl-subscriptions` |
| Fires | hourly, up to 5 min random delay | hourly, and once at login | hourly, up to 5 min random delay |
| Missed while off/asleep | runs once at boot (`Persistent=true`) | runs once on wake | runs when next possible (`StartWhenAvailable`) |
| A check still running at the next tick | not joined (oneshot service) | not joined | not joined (`IgnoreNew`) |
| Runs while logged out | only with `loginctl enable-linger` | no | no (no stored password) |

All three run the **pwsh that ran `install`**, by absolute path, with the
`PATH` that `install` ran with plus `~/.local/bin` and `~/.deno/bin` (and
Homebrew's prefixes on macOS) — a user manager's or launchd's own `PATH`
contains neither yt-dlp nor deno. A non-default `YTDLP_INSTALL_ROOT` is
carried into the job. If you move pwsh, or change `YTDLP_INSTALL_ROOT`, run
`install` again.

Platform notes:

- **Linux.** With no systemd user session (WSL1, a container, a login over
  ssh with no user manager) `install` refuses and prints the equivalent cron
  line instead. With lingering off, the timer stops when you log out; status
  says so, and `loginctl enable-linger $USER` changes it.
- **macOS.** macOS shows a "Background Items Added" notice naming pwsh when
  the agent is installed. A data root under `~/Documents`, `~/Desktop`,
  `~/Downloads` or on a removable volume may need pwsh granted access in
  *System Settings → Privacy & Security* before a scheduled check can write
  there; the default `~/yt-dlp` needs nothing. `--cookies-from-browser`
  reads the browser's keychain entry, which can prompt — and a prompt with
  nobody to answer it stalls a scheduled check. Prefer `--cookies FILE` for
  subscriptions on macOS.
- **Windows.** The task runs as you, only while you are signed in, and asks
  for no password. A console window flashes briefly when it starts; that is
  pwsh starting hidden, and there is no supported way to avoid it without
  storing a password. The execution time limit is removed, because the
  default 72 hours would kill a first check of a very large channel.

---

## Concurrency

Three locks, all in the install root. All are files opened with
`FileShare.None` or shared, which .NET implements with `flock()` on Linux and
macOS — so the kernel releases them when a process dies, and a killed check
never leaves a stale lock.

| Lock | Held | By |
|---|---|---|
| `configs/.subscriptions.lock` | exclusively, for each read-modify-write of the list | every command that changes it, and the runner when it records a result |
| `.subscriptions-run.lock` | exclusively, for a whole `--run-subscriptions` | the runner; a second one exits 3 |
| `.session.lock` | **shared**, for a whole download session | every `run_ytdlp.ps1` |

Before each subscription a due-only run tries `.session.lock` exclusively.
Failing means a download is running, and the check waits for the next
heartbeat. That guarantees a scheduled check never *starts* while you are
downloading, so the two cannot both pick up the same new upload and write
the same `.part` file.

It does not stop a download you start *while* a check is running; that goes
ahead, exactly as a second terminal always has. Making it wait would mean an
app's Add button doing nothing for as long as a first check of a large
channel takes. The two sessions write different session logs and share only
the files `postprocess.ps1` already locks.

The lock is in the install root rather than the data root because a data root
can be a VMware shared folder or a network mount where `flock()` is not
supported — and .NET silently skips the lock there, which would make every
session invisible to the check.

---

## The JSON contract

`ytdl --subscriptions --json` prints **one JSON document on stdout and nothing
else**, the rule `docs/probe-contract.md` sets for `--probe`: a consumer
decides whether the command worked by whether it got parseable JSON.
`ytdl --schedule status --json` prints the `schedule` object on its own.

### Versioning

`subscriptions_version` is **1**. It is bumped when a field is removed or
changes meaning, never when one is added; a consumer should ignore fields it
does not know, and refuse a version it does not know rather than guess. The
same number versions `configs/subscriptions.json`, which is this document
without the computed fields.

**All timestamps are Unix seconds, UTC** — integers, never ISO 8601 strings.
PowerShell's `ConvertFrom-Json` turns an ISO string into a local `DateTime`
and writes it back with the reading machine's offset, and three frontends in
three languages read an integer identically.

### Top level

| Field | Type | |
|---|---|---|
| `subscriptions_version` | int | 1 |
| `now` | int | the time the document was made; compute "3 h ago" against this, not the reader's clock |
| `schedule` | object | below |
| `subscriptions` | array | below; `[]` when there are none |

### `schedule`

| Field | Type | |
|---|---|---|
| `mechanism` | string | `systemd`, `launchd` or `task-scheduler` |
| `supported` | bool | false when this machine's scheduler cannot be reached (no systemd user session) |
| `installed` | bool | the job's files or task exist |
| `active` | bool | the job is enabled and loaded |
| `running` | bool | a `--run-subscriptions` is running right now, scheduled or not |
| `next_check` | int or null | when the scheduler says it fires next; null when it does not say (launchd never does) |
| `linger` | bool or null | Linux: whether checks continue after logout. null elsewhere |
| `detail` | string | one line for a person to read; always present |

### `subscriptions[]`

| Field | Type | |
|---|---|---|
| `id` | string | eight lowercase hex characters; stable |
| `url` | string | as given to `--subscribe` |
| `name` | string or null | |
| `options` | string[] | `ytdl` option tokens, in canonical order, **proxy passwords masked** — for display, not for re-submitting |
| `data_root` | string or null | absolute; null is the default data root |
| `every_hours` | int | 1–720 |
| `enabled` | bool | false when paused |
| `added`, `updated` | int | |
| `last_run` | object or null | null until first checked |
| `next_due` | int or null | `last_run.started + every_hours × 3600`, or `now` if never checked; null when paused |
| `due` | bool | would a due-only run check it now (includes the 30-minute slack) |

### `last_run`

| Field | Type | |
|---|---|---|
| `started`, `finished` | int | |
| `result` | string | `ok`, `errors` or `failed` |
| `exit_code` | int | the session's |
| `touched`, `skipped`, `errors`, `warnings` | int | from the session summary line; 0 when none was printed |
| `trigger` | string | `schedule` (a due-only run) or `manual` (named, or `all`) |
| `message` | string or null | the session's last line when `failed`; null otherwise |

### What a frontend sends

A frontend never writes `configs/subscriptions.json`. It builds `ytdl`
command lines, like everything else it does:

| To | Run |
|---|---|
| list | `ytdl --subscriptions --json` |
| add, or change download options | `ytdl <url> <form options> <connection options> --subscribe [--every Nh] [--name T]` |
| pause / resume / re-time / rename | `ytdl --edit-subscription ID ...` |
| remove | `ytdl --unsubscribe ID` |
| check one now, in its own queue | `ytdl --run-subscriptions ID` — the output is an ordinary session's |
| turn the schedule on / off | `ytdl --schedule install` / `remove` |

A frontend never runs a timer of its own. That is the point of this design:
one scheduler, in the one place every frontend already shares.

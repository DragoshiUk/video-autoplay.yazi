# CLAUDE.md

Context for working on this repo. `README.md` is user-facing.

**Before touching `main.lua`, read its header comment block** — it's ~180
lines and is the real design doc: every piece of the cleanup / process
lifecycle is the way it is because a simpler version broke live, and the
comments say exactly how. This file is just the map.

## What it is

A yazi plugin: hovering an `mp4`/`webm` (and `swf`, transcoded first) plays
it muted + looped in the preview pane via `mpv`'s kitty video output driver.
Unlike `gif-autoplay.yazi`, mpv has to keep **running** while the file is on
screen — so this is a process-lifecycle problem, not just a graphics one.

Files: `main.lua` (large), `swf-header` (Python helper — `main.lua` calls
`Command("swf-header")`, so it must be on `PATH`; a copy is bundled and an
identical one lives in `~/.local/bin/`), `README.md`. No `package.toml`.

## Where it lives

Repo is `~/Projects/video-autoplay.yazi`, symlinked to
`~/.config/yazi/plugins/video-autoplay.yazi` — edits here are live on the
next hover. Public repo `DragoshiUk/video-autoplay.yazi`.

Note: the swf support (`98f6a8b`) was developed by editing the live plugin
copy directly; that's how it got ahead of an older `~/Work` checkout during
the 2026-08-31 relocation. Now that it's a symlink, edit here.

## Do NOT undo these (each fixed a live breakage)

- **Marker-file cleanup, never pid-tracking.** Each mpv spawn is wrapped in
  a shell watchdog that atomically claims
  `/tmp/yazi-video-autoplay-$USER.marker`; superseded watchdogs kill their
  own mpv on their next 0.1s poll. "Track the pid in `ya.sync` and kill it
  before spawning the next" was the first two designs — both leaked
  actively-burning orphaned mpv under fast-scroll concurrency (several
  overlapping `peek()` calls). No call site identifies or kills anything by
  pid.
- **`self.child = child` in `peek()` must stay.** yazi's `Command` is
  `kill_on_drop(true)` with no opt-out; if the child handle isn't reachable
  from `M`, Lua GC sends SIGKILL to the watchdog, skipping its TERM trap and
  orphaning mpv. Only ever clear/overwrite that field where the marker
  already supersedes the old process.
- **The async yield point after spawn** (`read_line_with`) — without a
  genuine await after `Command:spawn()`, a fresh hover sits on the priming
  frame and never plays (superseded-task cancellation only lands at a yield
  point).
- **mpv kitty-VO flags**: `--vo-kitty-config-clear=no` (default `yes` wipes
  yazi's panes), `--vo-kitty-width/height` always passed together with
  `--vo-kitty-cols/rows` (else inflated per-cell density → oversized
  video), `--vo-kitty-alt-screen=no` plus the explicit "delete all images"
  escape and cursor reset in **both** cleanup paths (mpv's kitty VO is
  designed to leave its last image and cursor position on screen).
  `--video-aspect-override` forces exact box fit (mpv has no
  `--unicode-placeholder` equivalent).
- **swf transcode runs lazily from `peek()` only, never `preload()`.**
  `preload()` transcoding every swf scrolled past caused a blocking
  Ruffle+ffmpeg backlog bad enough to be an emergency-disable (screen
  flashing). `MAX_CONCURRENT_TRANSCODES` bounds it.

## Tried and reverted (don't retry without root-causing)

Per-yazi-instance marker scoping (to fix two yazi windows sharing one
marker). Reverted — appeared to make every hover spawn a never-superseded
watchdog; suspected the module re-executes per invocation, breaking the
"MARKER constant for the process lifetime" assumption. Single-marker-per-user
is the confirmed-working state; the two-windows-collide issue is the known,
milder cost.

## Requirements

yazi + kitty, `mpv` built with the kitty VO (`mpv --vo=help | grep kitty`),
`ffmpeg`, `sh` on `PATH`. For swf: Ruffle's `exporter` (build it yourself —
no binary release), `ffmpeg`, `swf-header` on `PATH`. swf is the least-solid
path ("kind of works").

## Testing

Manual, and the interesting cases are all about cleanup:
- hover mp4/webm → plays; navigate away → stops, no stuck frame, cursor OK
- video → video directly → new one starts clean, old one gone
- fast-scroll a directory full of videos → no orphaned mpv left behind
  (`pgrep mpv` after) — this is the torture test the marker design exists for
- hover an swf → transcodes then plays (still frame if not animating)

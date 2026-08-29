# video-autoplay.yazi

A [yazi](https://yazi-rs.github.io/) plugin that auto-plays mp4/webm
previews — muted, looped, no controls — in the preview pane, using
[mpv](https://mpv.io/)'s kitty terminal-graphics output driver.

Nothing in this plugin is actually format-specific beyond a short
extension list (see `VIDEO_EXTS` in `main.lua`) — `ffmpeg` (priming) and
`mpv` (playback) both handle any container either supports, so extending
this list to any other format `mpv` plays is a two-line change:
`VIDEO_EXTS` in `main.lua`, plus a matching mime rule in `yazi.toml`.

This is the companion to
[gif-autoplay.yazi](https://github.com/DragoshiUk/gif-autoplay.yazi), same
idea applied to video. It's a substantially harder problem than GIF, for one
core reason: a GIF is small enough to hand the terminal all at once and let
kitty loop it forever with nothing left running. Video isn't — `mpv` has to
stay alive and keep streaming frames for as long as the file is on screen,
which turns "clean up when you're done" into a real process-lifecycle
problem, not just a graphics-state one. Getting that right end-to-end took
three broken live attempts. This README explains the working design in
detail, including the two that didn't work, because the reasons they failed
are the actual content here.

## What it does

Hover an `.mp4` or `.webm` in yazi and it plays automatically — muted,
looped, scaled to fill the preview pane — using `mpv --vo=kitty`. Move to
another file and it stops and cleans up. That's the whole feature;
there's no seek/pause/volume control, by design.

## Requirements

- yazi, with a kitty-graphics-protocol-capable terminal — developed and
  tested against kitty itself
- [mpv](https://mpv.io/) built with the `kitty` VO (`mpv --vo=help | grep
  kitty` to check)
- `ffmpeg` (used to grab a priming thumbnail — see below)
- `sh` on `PATH` (any POSIX shell; the watchdog script doesn't require bash
  specifically, though it's what this was developed and tested against)

Falls back to yazi's normal static preview on any other terminal/adaptor, or
if `mpv`/`ffmpeg` aren't found.

## Installation

Via yazi's plugin manager:

```sh
ya pkg add DragoshiUk/video-autoplay
```

Or manually:

```sh
git clone https://github.com/DragoshiUk/video-autoplay.yazi ~/.config/yazi/plugins/video-autoplay.yazi
```

## Configuration

Add previewer rules to `~/.config/yazi/yazi.toml`, and a wildcard preloader
rule for cleanup (see below for why the preloader is needed):

```toml
[plugin]
prepend_previewers = [
    { mime = "video/mp4", run = "video-autoplay" },
    { mime = "video/webm", run = "video-autoplay" },
    { mime = "video/*", run = "video" }, # yazi's built-in, for everything else
]

prepend_preloaders = [
    { url = "*", run = "video-autoplay" },
]
```

That's it — no further options.

## How it works, and why

### The core problem: this can't be "transmit once and forget" like a GIF

kitty's graphics protocol supports genuinely *terminal-driven* animation:
transmit an image's frames plus a loop count, and the terminal owns all
future redraws — the sending process doesn't need to stay alive. That's
exactly why `gif-autoplay.yazi` works the way it does. Video doesn't fit
that model — you can't hand a multi-minute video to the terminal up front
— so `mpv` has to keep running and streaming frames live, for as long as
the file is being previewed. That single fact is the source of almost
every problem below: cleanup is now a *process* lifecycle problem, not
just a graphics one, and video positioning has to interoperate with
`mpv`'s own idea of how to draw to a terminal, which was never designed to
share one with another TUI.

### Cleanup, attempt 1 (broken): track a pid, kill it before spawning a new one

The obvious design: keep the current video's pid in `ya.sync` state, and
before spawning a new one, kill whatever's there. This leaked real,
actively-CPU-burning orphaned `mpv` processes the first time it was tested
with normal fast scrolling through a directory of videos — sometimes
*several* accumulated, all playing over each other. Root cause: `peek()`
can legitimately fire more than once in quick succession for different
files — scrolling does this routinely, producing several concurrent,
overlapping `peek()` invocations — and "kill the previous one before
spawning" is racy under that concurrency: a later call's spawn can
overwrite the tracked pid before an earlier call's own kill has run,
permanently losing track of it. Switching from a single tracked pid to a
list of tracked pids didn't fully fix it either, for the same underlying
reason — the accounting can still lose entries under enough concurrent
overlap.

### Cleanup, attempt 2 (the one that shipped): a self-evicting marker file

Instead of Lua code trying to identify and kill the *right* process at the
right time — which is exactly what kept going wrong — nothing does that
at all. Every spawn is wrapped in a small shell watchdog. The moment it
starts, it atomically claims a single well-known marker file as its own
(write-then-rename), then polls it once every 0.1s: if the marker no
longer names *this* watchdog's own pid, or `$PPID` (yazi, captured at
startup) has died, it kills its `mpv` and exits. Spawning a new instance
for a different file doesn't hunt down and kill the old one — it just
claims the marker for itself, and the *old* watchdog notices on its own
very next poll tick and evicts itself. Leaving video entirely deletes the
marker, which every currently-running watchdog treats identically to
being superseded.

This was verified directly before trusting it: three watchdogs spawned to
race for the same marker concurrently, every time, and the two superseded
ones killed their own child within their first 0.3s poll — no orphans, no
matter how the race landed. The property this design gives you is
specifically the one attempt 1 was missing: no call site needs to
correctly identify or kill anything by pid, ever. Every watchdog is
independently responsible for noticing it's stale.

Leaving video is signaled from two places. The reliable one is a
`ps.sub("hover")` subscription — yazi's own navigation event, fired by the
actor that handles hover changes, on *every* hover change, uncached.
`preload()` looked like the natural hook for this at first, but it's a
preview-pipeline optimization that appears to cache per file — in a long
session it stops re-firing for files already hovered earlier, which
manifested live as "video keeps playing after moving to a completely
different, already-seen file." `preload()` is kept as a backup (cheap,
and covers the hover subscription failing to register), but `ps.sub` is
the one actually doing the job.

### Cleanup, attempt 3: `kill_on_drop` and a required yield point

With the marker-file design working, a *single* fresh hover still didn't
play — it just sat on the static priming frame, nothing more. Root cause,
found by reading yazi's own `Command` binding
(`yazi-binding/src/process/command.rs`): *every* `Command` it spawns is
created with `kill_on_drop(true)`, unconditionally, with no exposed way to
turn it off. `Command:spawn()`'s returned `child` handle was a plain local
in `peek()` that nothing kept a reference to — so the instant `peek()`
returned, it became eligible for Lua's garbage collector, and whenever
that GC actually ran, yazi sent `SIGKILL` straight to the watchdog.
`SIGKILL` can't be trapped, so it skipped right past the `TERM`/`INT`
handler that was supposed to clean up `mpv`, orphaning it with nothing
left managing it. This is what produced every orphan actually observed —
not a flaw in the watchdog's own logic, a flaw in what was (not) holding
onto its handle.

Whether this was winnable as a *race* (fork the real work off immediately,
let the short-lived wrapper process that `kill_on_drop` can actually reach
exit on its own before being caught) was tested directly — it survived
some immediate-`SIGKILL` tests and not others. Genuinely unwinnable, not
worth trying to outrun. The actual fix doesn't race it at all:
`self.child = child` keeps the handle reachable for as long as it should
keep running, since `M` (`self`) is exactly what yazi itself must hold
onto to be able to call `peek()`/`preload()` on the plugin again — Lua's
GC only collects what's unreachable. Overwriting or nil-ing that field is
what *lets* `kill_on_drop` finally fire, and that only happens at the same
points the marker file has already superseded the process anyway, so it's
a redundant backup, not something the design depends on for timing.

One more layer on top of *that*: even with the reference retained, a
single fresh hover *still* didn't play, until `peek()` gained a genuine
async yield point after spawning. `Command:spawn()` itself is synchronous,
and before this fix nothing in `peek()` ever awaited anything after
calling it — so the whole function ran as one uninterrupted synchronous
burst. Best working hypothesis (not confirmed against yazi's scheduler
source, but forcing a yield point is what fixed it live): yazi's own
preview-task scheduler cancels superseded `peek()` tasks, and — standard
`tokio::task::abort()` behavior — that cancellation only takes effect at a
task's next yield point. A task that runs synchronously start-to-finish
may be getting caught up in whatever happens to a "just-finished" task
before it's properly landed as the active preview. A `child:read_line_with`
call with a short timeout supplies that yield point; the code doesn't care
what (if anything) comes back.

### Priming: why it doesn't reuse yazi's own cache, and why it can't skip it

`ya.image_show` only decodes actual image formats — it can't read an
mp4/webm container directly. `gif-autoplay.yazi`'s equivalent fallback
(show the raw file if there's no cache) works fine for GIF, since GIF *is*
a decodable image format; for video that same fallback fails outright,
which silently skips straight past ever spawning `mpv`. So when there's no
cached thumbnail, this plugin grabs one real frame via `ffmpeg` first
(fast — it seeks to frame zero, not a full decode) and primes with that.

It deliberately does *not* check `ya.file_cache(job)` first the way
`gif-autoplay.yazi` does, even though that looks like the obvious
optimization. For GIF, a cache hit there is just a resized copy of the
*same* frame, so using it is safe. For video, `ya.file_cache` can be
populated by an entirely different mechanism — e.g. yazi's own default
video previewer, before this plugin overrode it — as a genuine thumbnail
from an arbitrary point in the video, not equivalent content, just
whatever that other tool happened to pick. Using it caused a jarring flash
of an unrelated frame before `mpv`'s actual first frame took over. Always
extracting fresh at `-ss 0` guarantees the priming frame matches what
`mpv` is about to show, at the cost of one fast `ffmpeg` call (~70ms) per
hover.

Why prime with a static frame at all, if `mpv` is about to draw over it
anyway? Registering it. yazi's kitty driver tracks one "currently shown"
rect internally and erases it before drawing the next preview — but only
for images shown through `ya.image_show`. The actual animated draw
bypasses that call entirely (it's `mpv`, not yazi's own renderer), so
without this, yazi never learns anything is on screen there, and that
erase-before-draw never fires once you move to the next file.

### Alignment: no stretch-to-fill flag, so the aspect ratio is overridden instead

Unlike `icat` (see `gif-autoplay.yazi`), `mpv`'s kitty VO has no
equivalent of `--unicode-placeholder` / stretch-to-fill placement — it
aspect-fits within whatever box it's given instead of filling it exactly,
which is the same sliver-at-the-edge symptom `icat` had before that flag
fixed it for GIFs. There's no equivalent flag for `mpv`, so this reaches
the same result a different way: `--video-aspect-override` forces the
video's *aspect ratio itself* to exactly match the target box's, so
there's nothing left for an aspect-preserving fit to letterbox, since box
and content ratio are now identical by construction.

### Graphics footguns, discovered live

All of these come from the same root cause: `mpv`'s kitty VO was never
designed to share a screen with another TUI.

- **`--vo-kitty-cols`/`--vo-kitty-rows` alone only tell `mpv` the *cell*
  dimensions.** The matching `--vo-kitty-width`/`--vo-kitty-height`
  (pixels) default to auto-detecting the *whole terminal's* pixel size if
  left unset, which combined with a small cell count gives `mpv` an
  inflated per-cell pixel density — this is why video was rendering
  larger than its pane instead of scaled to it. Both must be passed
  together, computed from the same cell size.
- **`--vo-kitty-config-clear` defaults to `yes`**: `mpv` clears (part of)
  the terminal itself whenever it reconfigures, including on startup —
  not scoped to just its own cells, so this was wiping out yazi's own
  panes (the directory tree specifically). Must be explicitly set to `no`.
- **`--vo-kitty-alt-screen=no`** (needed, to avoid `mpv` taking over the
  whole screen) documents that "the last kitty image stays on screen
  after quit" — it's *designed* to never clean up its own image on exit,
  even gracefully. Handled two different ways depending on why a
  watchdog is exiting: video-to-video, the *new* watchdog sends a
  "delete all images" escape itself right before `mpv` draws its first
  frame, so each new video always starts from a clean slate regardless
  of what the old one left behind. Leaving video entirely, there's no new
  watchdog to do that, so the dying watchdog clears it — but only
  *after* confirming `mpv` is actually dead, not immediately when it
  notices the marker is gone. An immediate clear races against `mpv`'s
  own continued streaming (it can draw another frame right over an
  "immediate" clear before it's actually killed — this is exactly why an
  early version of this fix only cleared the stuck frame "most of the
  time"), and clearing unconditionally on *every* exit would wipe out a
  new video's already-drawn frame in the video-to-video case — so the
  watchdog distinguishes "marker now names a different pid" (a new video
  is already clearing-and-drawing; don't also clear here) from "marker is
  gone entirely" (nothing else is going to, so this exit must).
- **The cursor gets left wherever `mpv` last positioned it.** Same
  "designed to leave things as-is" behavior as above — `mpv`'s kitty VO
  moves the cursor to track its own drawing and never restores it, so
  that position can persist all the way through to the shell prompt after
  quitting yazi. Both cleanup paths above also hard-reset the cursor to
  the terminal's top-left corner.
- **Occasional literal garbage text** (a fragment like `35;69H`,
  overwriting yazi's own header) from raw escape sequences getting torn
  by concurrent writes. `mpv` and yazi are two independent processes
  writing directly to the same terminal with no way to coordinate — yazi
  has an internal lock around its *own* writes specifically to prevent
  this kind of tearing (`Emulator::move_lock` in its kitty driver), but
  it isn't exposed to plugins, so nothing external can participate in it.
  **Not fully fixable from a plugin** — there's no lock to acquire from
  here. Self-corrects on yazi's very next redraw; hasn't been observed to
  be more than a cosmetic, occasional flicker.

## Limitations

- **kitty-only.** Other terminals/adaptors fall back to yazi's default
  static-first-frame behavior.
- No seek, pause, volume, or any playback controls. Always-on autoplay,
  muted, looped, for as long as the file is being previewed.
- The occasional torn-escape-sequence flicker described further down is a
  known, currently unfixable-from-here *cosmetic* issue.
- Every `peek()` re-spawns `mpv` + `ffmpeg` (a fast process each, but
  still real process spawns). A 0.15s debounce means scrolling quickly
  through many videos mostly skips this work for files you scroll past,
  but it's not free.

## License

MIT — see [LICENSE](LICENSE).

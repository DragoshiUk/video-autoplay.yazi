--- @since 26.1.22
--
-- INCIDENT (2026-08-29): swf-as-video support (transcode via Ruffle, then
-- play through this file's mpv machinery) caused mpv to get stuck looping
-- indefinitely with multiple instances overlapping, plus slow directory
-- traversal, badly enough to be an emergency-disable (rapid on-screen
-- flashing). Re-enabled after finding two compounding causes, both fixed:
--   1. preload() was transcoding every swf merely scrolled past, not just
--      the one actually previewed -- a backlog of multi-second, blocking
--      Ruffle+ffmpeg calls. Fixed: transcode_swf() now only ever runs
--      lazily from peek(), matching how real video priming already works
--      elsewhere in this file (preload() never did the expensive work for
--      that either, only cleanup).
--   2. peek()'s "busy" (concurrency-limited) path used to self-retry via
--      ya.emit("peek", {..., only_if=..., force=true}) -- suspected,
--      not fully confirmed, that force=true bypassed the only_if guard,
--      letting a backlogged retry spawn mpv for a file long since
--      scrolled past. Fixed by removing the retry: "busy" now just
--      renders blank and waits for the next natural hover.
-- Together these should mean transcode_swf() is essentially never
-- contended in normal use (only one peek() is "current" at a time), so
-- MAX_CONCURRENT_TRANSCODES should rarely even matter now.
--
-- Auto-plays mp4/webm previews (muted, looped) in the preview pane, using
-- mpv's kitty terminal-graphics output driver. Nothing here is actually
-- format-specific beyond the VIDEO_EXTS extension list below -- ffmpeg
-- (priming) and mpv (playback) both handle any container either supports,
-- so adding a format is just adding its extension there and a matching
-- mime rule in yazi.toml.
--
-- Unlike gif-autoplay.yazi, this can't be a one-shot "transmit frames, let
-- the terminal loop them" trick: video is too big to hand the terminal all
-- at once, so mpv has to keep running and streaming frames for as long as
-- the file is on screen. That turns "clean up when you're done" into a
-- real process-lifecycle problem, not just a graphics-state one.
--
-- Cleanup design (this took three broken attempts to get right):
--
-- 1. Every spawn is wrapped in a small shell watchdog that, the moment it
--    starts, atomically claims a single well-known marker file as its own
--    (write-then-rename) and then polls once every 0.1s -- short, since an
--    old video's process staying alive a moment longer means it's also
--    still actively redrawing over whatever we clear (see the graphics
--    note below): if the marker no longer names *this* watchdog's own
--    pid, or $PPID (yazi, at the time it started) has died, it kills its
--    mpv and exits. Spawning a new instance for a different file doesn't
--    need to hunt down and kill the old one at all -- it just claims the
--    marker for itself, and the old watchdog notices on its own very next
--    poll tick and evicts itself. Leaving video entirely (any non-video
--    file hovered) just deletes the marker, which every currently-running
--    watchdog treats identically to being superseded. That deletion is
--    triggered from two places: a ps.sub("hover") subscription (yazi's
--    own uncached, fires-on-every-hover-change navigation event -- see
--    the note by is_video below) as the reliable primary, and preload()
--    as a backup. This is deliberately NOT "track the current pid in
--    ya.sync state and explicitly kill it before spawning a new one" --
--    that was the first two designs, and both leaked real, actively-CPU-
--    burning orphaned mpv processes the moment peek() fired more than
--    once in quick succession for different files (which plain fast
--    scrolling does routinely, spinning up several concurrent, overlapping
--    peek() calls). Getting explicit "kill the right pid at the right
--    time" correct under that concurrency is fiddly and we got it wrong
--    twice live. The marker-file approach sidesteps the problem instead
--    of trying to solve it more carefully: no call site needs to identify
--    or kill anything by pid at all, every watchdog is independently
--    responsible for noticing it's stale and killing *itself*. Verified
--    directly: three watchdogs spawned to race for the same marker
--    concurrently, and the two superseded ones killed their own child
--    within their very first 0.3s poll, every time.
--
-- 2. Even with that working, a single fresh hover still didn't play --
--    just sat on the static priming frame. Root cause, found by reading
--    yazi's own Command binding (yazi-binding/src/process/command.rs):
--    *every* Command it spawns is created with kill_on_drop(true),
--    unconditionally, with no exposed way to turn it off. The `child`
--    handle Command:spawn() returns is a plain local in peek() that we
--    weren't keeping a reference to anywhere -- so the instant peek()
--    returns, it's eligible for Lua's GC, and whenever that GC actually
--    runs, yazi sends SIGKILL straight to our watchdog. SIGKILL can't be
--    trapped, so it skips right past the TERM/INT trap that was supposed
--    to clean up mpv, orphaning it with nothing left managing it -- this
--    is what actually produced every orphan we found, not a flaw in the
--    watchdog's own logic. We confirmed this isn't a timing fluke worth
--    trying to outrun either: wrapping the watchdog's own startup in a
--    detached double-background (fork the real work off immediately, let
--    the outer process Command tracks exit on its own) survived some
--    immediate-SIGKILL tests and not others -- a genuine race, not
--    reliably winnable. The actual fix doesn't try to win that race at
--    all: `self.child = child` below keeps the handle reachable for as
--    long as we want it to keep running, since M (self) is exactly what
--    yazi itself must hold onto to be able to call peek()/preload() on it
--    again -- Lua's GC only collects what's unreachable. Overwriting or
--    nil-ing that field is what *lets* kill_on_drop finally fire, and we
--    only ever do that at the same points the marker file already
--    supersedes the old process, so it's a redundant backup, not
--    something we depend on for timing.
--
--    One more wrinkle on top of that: even with the reference retained, a
--    single fresh hover still didn't play until peek() gained a genuine
--    async yield point after spawning (see the read_line_with call below).
--    Command:spawn() itself is synchronous, and before that yield point
--    nothing in peek() ever awaited anything after it, so the whole call
--    ran as one uninterrupted synchronous burst. Best working hypothesis:
--    yazi's own preview-task scheduler cancels superseded peek() tasks,
--    and (standard tokio::task::abort() behavior) that cancellation only
--    takes effect at a task's next yield point -- a task that runs
--    synchronously start-to-finish may be getting caught up in whatever
--    that cancellation does to a "just-finished" task before it ever
--    properly lands as the active preview. Not confirmed against yazi's
--    scheduler source, but forcing a yield point is what fixed it live.
--
-- Priming: ya.image_show only decodes actual image formats -- it can't
-- read a video container directly, of any kind. gif-autoplay's fallback
-- (show the raw file if there's no cache) works there because GIF *is* a
-- decodable image format; for video that fallback fails outright, which
-- silently skips straight past spawning mpv. So when there's no cached
-- thumbnail, we grab one real frame via ffmpeg first (fast: it seeks to
-- the first frame, not a full decode) and prime with that instead.
--
-- Alignment: unlike icat (see gif-autoplay.yazi), mpv's kitty VO has no
-- equivalent of --unicode-placeholder / stretch-to-fill placement, so it
-- aspect-fits within whatever box it's given instead of filling it exactly
-- -- the same sliver-at-the-edge symptom icat had before that flag fixed
-- it for GIFs. There's no equivalent flag for mpv, so we reach the same
-- result a different way: --video-aspect-override forces the video's
-- *aspect ratio itself* to exactly match the box's, so there's nothing
-- left for an aspect-preserving fit to letterbox, since box and content
-- ratio are now identical by construction.
--
-- Graphics footguns discovered live, all from mpv's kitty VO not being
-- designed to share a screen with another TUI:
--  - --vo-kitty-cols/rows alone only tell mpv the *cell* dimensions; the
--    matching --vo-kitty-width/height (pixels) default to auto-detecting
--    the *whole terminal's* pixel size if left unset, which combined with
--    a small cell count gives mpv an inflated per-cell pixel density --
--    this is why video was rendering larger than its pane instead of
--    scaled to it. Both must be passed together, from the same cell size.
--  - --vo-kitty-config-clear defaults to yes: mpv clears (part of) the
--    terminal itself whenever it reconfigures, including on startup --
--    not scoped to just its own cells, so this was wiping out yazi's own
--    panes. Must be explicitly set to no.
--  - --vo-kitty-alt-screen=no (which we need, to avoid mpv taking over the
--    whole screen) documents that "the last kitty image stays on screen
--    after quit" -- i.e. it's *designed* to never clean up its own image
--    on exit, even gracefully. Two consequences, handled two different
--    ways: (a) video-to-video, the *new* watchdog sends a "delete all
--    images" escape itself right before mpv draws its first frame, so
--    each new video always starts from a clean slate regardless of what
--    the old one left behind; (b) leaving video entirely, there's no new
--    watchdog to do that, so the dying watchdog has to clear it -- but
--    only *after* confirming mpv is actually dead (kill -9 already sent),
--    not immediately when it notices the marker is gone/reassigned. An
--    immediate clear races against mpv's own continued streaming (it can
--    still draw another frame right over an "immediate" clear before it's
--    actually killed, which is exactly why an early version of this fix
--    only cleared the stuck frame "most of the time"), and clearing on
--    every exit indiscriminately would wipe out a *new* video's
--    already-drawn frame in the video-to-video case -- so the watchdog
--    distinguishes "marker now names a different pid" (a new video is
--    already clearing-and-drawing; don't also clear here) from "marker is
--    gone entirely" (nothing else is going to, so this exit must).
--  - mpv's kitty VO moves the cursor to track its own drawing and never
--    restores it (same "designed to leave things as-is" behavior as
--    above), so whatever position it was last left at can otherwise
--    persist all the way through to the shell prompt after quitting yazi.
--    Both cleanup paths above also hard-reset the cursor to top-left.
--  - mpv and yazi are two independent processes writing raw escape
--    sequences to the same terminal with no way to coordinate -- yazi has
--    an internal lock around its own writes (Emulator::move_lock in its
--    kitty driver) specifically to prevent this kind of tearing, but it
--    isn't exposed to plugins, so an external process's writes can't
--    participate in it. An escape sequence can occasionally get torn by a
--    concurrent write from yazi's own redraw, which prints as literal
--    garbage text (a fragment like "35;69H") whereever the cursor happens
--    to be -- typically yazi's own header, since that's redrawn often. Not
--    fully fixable from a plugin: there's no lock to acquire. Self-corrects
--    on yazi's next redraw; hasn't been observed to be more than cosmetic.
--
-- Only works when the frontend is kitty and mpv is built with the kitty
-- VO. Falls back to a normal static preview otherwise.

local M = {}

-- REVERTED (2026-08-29): tried scoping this per-yazi-instance (see git
-- history) to fix two concurrent yazi windows fighting over one marker
-- file. Reverted, unverified, after it appeared to cause every mp4/webm
-- hover to spawn a new, never-superseded watchdog instead -- suspected
-- cause: yazi may re-execute this module fresh per plugin invocation
-- rather than loading it once per process, which would silently break
-- the "MARKER is a stable constant for this process's lifetime"
-- assumption the instance-scoping attempt depended on. Not confirmed;
-- reverted fast because it was causing multiple videos to play at once,
-- not root-caused. Back to the original single-marker-per-user scheme,
-- which has the known (much milder) two-yazi-instances-collide issue but
-- is the last confirmed-working state.
local MARKER = "/tmp/yazi-video-autoplay-" .. (os.getenv("USER") or "shared") .. ".marker"

-- Best-effort only, purely to skip redundant respawns of the file already
-- playing (e.g. a resize re-firing peek()) and to avoid wasting a
-- ffmpeg+mpv spawn on a file the user has already scrolled past. Not
-- relied on for correctness -- the marker file is what guarantees no
-- orphaned process, regardless of how this races.
local set_url = ya.sync(function(state, url)
	local changed = state.url ~= url
	state.url = url
	return changed
end)

local current_url = ya.sync(function(state)
	return state.url
end)

local clear_url = ya.sync(function(state)
	state.url = nil
end)

local VIDEO_EXTS = { mp4 = true, webm = true }
local SWF_EXTS = { swf = true }

local function ext_of(url)
	return tostring(url):lower():match("%.([%w]+)$")
end

-- "Is this something this plugin will animate" -- true for real videos AND
-- swf (transcoded to an mp4 first, see SWF TRANSCODING below), since both
-- need the same hover-cleanup/marker-file lifecycle handling.
local function is_video(url)
	local ext = ext_of(url)
	return ext ~= nil and (VIDEO_EXTS[ext] == true or SWF_EXTS[ext] == true)
end

local function is_swf(url)
	local ext = ext_of(url)
	return ext ~= nil and SWF_EXTS[ext] == true
end

-- The watchdog's own delete-all escape (see WATCHDOG below) only runs
-- when a *new* video starts, which is exactly why video-to-video
-- transitions were already clean -- the new watchdog wipes the old
-- frame before drawing its own. Leaving video entirely has no such "new
-- drawer" to trigger that cleanup: mpv just gets SIGKILLed, and with
-- --vo-kitty-alt-screen=no (which we need) it was never going to erase
-- its own last frame on exit anyway. So the same escape has to be sent
-- directly from here too, specifically on the "leaving video" path. Also
-- resets the cursor to top-left -- see the graphics notes up top.
local function clear_graphics()
	io.write("\27_Gq=2,a=d,d=A\27\\\27[H")
	io.flush()
end

-- preload() (used below as a backup) is a preview-pipeline optimization
-- and appears to cache per file -- in a long session it stops re-firing
-- for files already hovered earlier, which is exactly the "video keeps
-- playing after you've moved to a completely different, already-seen
-- file" bug this was hit by live. yazi's "hover" DDS event, by contrast,
-- is fired by the navigation actor itself (yazi-actor/src/mgr/hover.rs)
-- on every single hover change, uncached -- the reliable version of the
-- same signal, EXCEPT the event body's own url field turned out to
-- always be nil regardless of what's actually hovered: traced to
-- yazi-dds/src/pubsub.rs's EmberHover::owned(), whose second parameter
-- is literally named `_` and hardcodes url: None -- and Lua's ps.sub
-- receives that "owned" published form, not the "borrowed" one that
-- carries the real url. So this reads the actual hovered file back from
-- cx instead of trusting the event payload, using the event purely as
-- the "something changed, go check" signal. Hit live: relying on the
-- (always-nil) body.url meant every single hover change was treated as
-- "left video", including video-to-video and, worse, whatever hover
-- churn yazi's own live search does while typing -- each one firing
-- clear_graphics(), which was disrupting the search input itself.
-- Wrapped in pcall since plugin-load-time ps.sub is a bit unusual and we
-- don't want a failure here to break previewing entirely; if it fails,
-- preload() below still provides partial coverage.
local get_hovered_path = ya.sync(function(state)
	local h = cx.active.current.hovered
	return h and tostring(h.path) or nil
end)

local ok, sub_err = pcall(function()
	ps.sub("hover", function()
		local path = get_hovered_path()
		if path and is_video(path) then
			return
		end
		os.remove(MARKER)
		clear_url()
		M.child = nil
		clear_graphics()
	end)
end)
if not ok then
	ya.err("video-autoplay", "ps.sub(hover) registration failed", sub_err)
end

-- ─────────────────────────────────────────────────────────────
--  SWF TRANSCODING
--  mpv (via ffmpeg/libavformat) has no real Flash renderer -- its swf
--  demuxer only reads embedded FLV-style streams, not the vector/timeline
--  content that's actually in most Flash animations. So .swf is handled
--  completely differently from mp4/webm above: transcode once to a real
--  mp4 (cached under yazi's own file cache, keyed by content+mtime like
--  any other thumbnail) using Ruffle's `exporter` tool to rasterize every
--  frame, then hand that mp4's path to the exact same mpv/watchdog
--  machinery used for real videos below -- nothing past this point needs
--  to know the original file was ever a .swf.
--
--  --force-play bypasses "click to play" gates some Flash content has;
--  fine here since these are treated as non-interactive clips, so there's
--  no interactivity being lost.
--
--  Frame rate: ffmpeg/ffprobe can't reliably read a swf's header (tested
--  live: fails outright even on a plain uncompressed FWS-signature file,
--  not just compressed ones). `swf-header` (a small standalone script
--  alongside this plugin, on PATH via ~/.local/bin) parses it directly
--  instead -- signature, optional zlib/lzma decompression, skip the
--  stage-size RECT, read the 2-byte frame rate. Falls back to a guessed
--  24fps if that ever fails, rather than aborting the transcode over a
--  cosmetic timing mismatch.
--
--  Frame count comes from the swf header too, via the exporter's own
--  `--frames all`. Ruffle's own documented limitation, not something
--  worked around here: content whose actual frame count is driven by
--  nested clips beyond the main timeline's header count can end up
--  truncated. Acceptable for the non-interactive single-timeline clips
--  this is built for.
--
--  Throttled independently from the mpv/ffmpeg priming below -- this
--  spawns a GPU-rendering process per file, so scrolling fast through a
--  folder full of swf files shouldn't fire more than a couple of these
--  concurrently.
-- ─────────────────────────────────────────────────────────────
local active_transcodes = 0
local MAX_CONCURRENT_TRANSCODES = 2

local function swf_frame_rate(path)
	local out = Command("swf-header"):arg(path):stdout(Command.PIPED):stderr(Command.NULL):output()
	local fps = out and out.stdout and tonumber((out.stdout):match("^(%S+)"))
	return fps or 24
end

-- Some "interactive" swf content (button states, hidden layers driven by
-- click handlers rather than a linear timeline) doesn't have anything
-- resembling continuous motion on its main timeline -- --force-play just
-- steps the timeline forward regardless of what each frame actually
-- represents, so playing it back as video means looping through however
-- many distinct visual states it happens to have, however few.
--
-- First version of this (see git history) used PNG file size as a proxy
-- for "how much is actually drawn," clustering frames whose sizes jumped
-- by more than 30%. Wrong signal, confirmed live: real animation can have
-- roughly-constant visual complexity frame to frame (a moving character
-- against a similar background, say) despite the *pixels* constantly
-- changing -- two confirmed real regressions (a 184-frame and an
-- 18-frame clip) had file sizes that only ever drifted within a narrow
-- band, so the size-jump clustering saw ~1 cluster and wrongly called
-- them static, even though they're genuinely continuous motion throughout.
--
-- Fixed by measuring the actual thing that matters -- pixel content, not
-- compressed size -- via ImageMagick's `identify -format "%#"`, a hash of
-- the decoded pixels themselves (unaffected by PNG compression variance).
-- Counting *distinct* hashes across all frames directly answers "how many
-- unique visual states does this timeline actually have": confirmed live,
-- real animation has a high distinct-to-total ratio (e.g. 86/184, 32/44)
-- since content keeps changing, while degenerate/interactive timelines
-- collapse to 1-2 distinct states regardless of frame count (confirmed on
-- a 1220-frame file that's genuinely just one still, and the original
-- content/blank/blank/.../content flashing case). 1-2 distinct states
-- means "this timeline isn't animating" -- fall back to a single static
-- frame (the largest file size among them, as a proxy for most detailed)
-- instead of assembling a video.
--
-- Two or fewer header frames is treated as static unconditionally, same
-- conclusion by construction rather than by counting: distinct states
-- can only ever be 1 or 2 regardless of content, so the counting logic
-- can't tell anything apart there anyway, and a real intentional
-- animation is never authored as just 1-2 main-timeline frames.
local function classify_frames(frame_paths)
	local n = #frame_paths
	if n <= 2 then
		return "static"
	end

	local cmd = Command("magick"):arg("identify"):arg("-format"):arg("%#\n")
	for _, p in ipairs(frame_paths) do
		cmd = cmd:arg(p)
	end
	local out = cmd:stdout(Command.PIPED):stderr(Command.NULL):output()
	if not out or not out.stdout then
		return "video" -- couldn't hash frames; default to the safer (never-blank) behavior
	end

	local seen, distinct = {}, 0
	for hash in out.stdout:gmatch("%S+") do
		if not seen[hash] then
			seen[hash] = true
			distinct = distinct + 1
		end
	end
	return distinct <= 2 and "static" or "video"
end

-- Returns (path, kind) on success, where kind is "video" (play play_path
-- as a looping mpv video, as normal) or "image" (a single static frame --
-- see classify_frames above -- render with ya.image_show instead, no mpv
-- involved at all). Returns nil (transcode failed, or skipped because
-- MAX_CONCURRENT_TRANSCODES is already busy) if not ready -- callers
-- should treat that as "not ready yet" and let a later preload()/peek()
-- retry, same as image-grid.yazi's cache-miss pattern.
--
-- Which kind a given cache entry is has to survive across cache hits too
-- (peek() re-checks every hover, potentially long after the transcode
-- that decided it), so it's recorded as an empty sidecar marker file
-- next to the cache entry itself rather than recomputed.
local function transcode_swf(job)
	local cache = ya.file_cache(job)
	if not cache then
		return nil
	end
	local marker = tostring(cache) .. ".static"
	if fs.cha(cache) then
		return tostring(cache), (fs.cha(Url(marker)) and "image" or "video")
	end
	if active_transcodes >= MAX_CONCURRENT_TRANSCODES then
		return nil, "busy"
	end
	active_transcodes = active_transcodes + 1

	local path = tostring(job.file.path)
	local frame_dir = os.tmpname()
	os.remove(frame_dir)
	Command("mkdir"):arg({ "-p", frame_dir }):status()

	local export_status = Command("ruffle-exporter")
		:arg({ path, frame_dir, "--frames", "all", "--force-play", "--silent" })
		:stdout(Command.NULL)
		:stderr(Command.NULL)
		:status()

	if not export_status or not export_status.success then
		active_transcodes = active_transcodes - 1
		Command("rm"):arg({ "-rf", frame_dir }):status()
		ya.err("video-autoplay", "ruffle-exporter failed", path)
		return nil
	end

	local frames = fs.read_dir(Url(frame_dir), {})
	if not frames or #frames == 0 then
		active_transcodes = active_transcodes - 1
		Command("rm"):arg({ "-rf", frame_dir }):status()
		ya.err("video-autoplay", "ruffle-exporter produced no frames", path)
		return nil
	end
	table.sort(frames, function(a, b) return a.url.name < b.url.name end)

	local frame_paths = {}
	for i, f in ipairs(frames) do
		frame_paths[i] = tostring(f.url)
	end
	local kind = classify_frames(frame_paths)

	local ok
	if kind == "static" then
		local best, best_size = frames[1], -1
		for _, f in ipairs(frames) do
			if f.cha.len > best_size then
				best, best_size = f, f.cha.len
			end
		end
		ok = Command("cp"):arg({ tostring(best.url), tostring(cache) }):status()
		if ok and ok.success then
			Command("touch"):arg({ marker }):status()
		end
	else
		ok = Command("ffmpeg")
			:arg({
				"-y",
				"-loglevel", "error",
				"-framerate", tostring(swf_frame_rate(path)),
				"-pattern_type", "glob",
				"-i", frame_dir .. "/*.png",
				"-pix_fmt", "yuv420p",
				"-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
				"-f", "mp4",
				"-movflags", "+faststart",
				tostring(cache),
			})
			:stdout(Command.NULL)
			:stderr(Command.NULL)
			:status()
	end

	active_transcodes = active_transcodes - 1
	Command("rm"):arg({ "-rf", frame_dir }):status()

	if not ok or not ok.success then
		ya.err("video-autoplay", (kind == "static" and "static frame copy failed" or "ffmpeg frame assembly failed"), path)
		return nil
	end
	return tostring(cache), kind
end

-- Extracts a single frame near the start of the video to a temp file via
-- ffmpeg. Forces mjpeg output explicitly (-f) rather than relying on a
-- .jpg extension, since os.tmpname() doesn't give us one.
--
-- Takes an explicit `path` rather than reading job.file.path itself, so
-- the swf case above can hand in its transcoded mp4's path instead --
-- see the play_path computation in peek() below. For real video, callers
-- pass tostring(job.file.path), NOT job.file.url: hovering a file inside
-- yazi's search results gives a url like "search://mp4$:4:4//real/path/x.mp4"
-- -- a yazi-internal pseudo-URL, not something ffmpeg (or mpv) has any way
-- to open. job.file.path is the resolved real path either way (confirmed
-- identical to tostring(job.file.url) for a plain, non-search hover, so
-- this doesn't change behavior outside search results) --
-- yazi-shared/src/url/lua.rs's "path" field is exactly this resolution
-- (me.loc()), which is what ya.image_show does internally too
-- (as_local()), just not something we were doing ourselves for the raw
-- ffmpeg/mpv command lines.
local function extract_thumbnail(path)
	local tmp = os.tmpname()
	local status = Command("ffmpeg")
		:arg({
			"-y",
			"-loglevel",
			"error",
			"-ss",
			"0",
			"-i",
			path,
			"-frames:v",
			"1",
			"-f",
			"mjpeg",
			tmp,
		})
		:stdout(Command.NULL)
		:stderr(Command.NULL)
		:status()

	if not status or not status.success then
		os.remove(tmp)
		return nil
	end
	return tmp
end

-- Deliberately does NOT check ya.file_cache(job) first the way
-- gif-autoplay's equivalent does. There, a cache hit is just a resized
-- copy of the same frame, so using it is a safe optimization. For video,
-- ya.file_cache can be populated by an entirely different mechanism (e.g.
-- yazi's own default video previewer, before this plugin overrode it) as
-- a genuine thumbnail from an arbitrary point in the video -- not
-- equivalent content, just whatever that other tool picked. Using it here
-- caused a jarring flash of a random unrelated frame before mpv's actual
-- first frame took over. Always extracting fresh at -ss 0 guarantees this
-- matches what mpv is about to show, at the cost of one fast ffmpeg call
-- (~70ms) per hover -- acceptable given the 0.15s debounce already ahead
-- of this in peek().
--
-- ya.preview_widget (yazi-plugin/src/utils/preview.rs) only accepts nil, a
-- renderable (or table of them), or a proper mlua Error userdata -- never
-- a plain Lua string. ya.image_show's own failure already returns a
-- proper Error, safe to hand straight to preview_widget, but a plain
-- string here (e.g. "extraction failed") would make it throw "preview
-- widget must be a renderable element or a table of them" and take the
-- whole peek() down with it -- hit live on a real file that ffmpeg
-- couldn't extract a frame from. So extraction failure logs its own
-- detail via ya.err and returns a plain nil second value, not a string,
-- keeping whatever comes out of this function always safe to hand
-- directly to ya.preview_widget.
local function prime(job, path)
	local tmp = extract_thumbnail(path)
	if not tmp then
		ya.err("video-autoplay", "could not extract a thumbnail frame via ffmpeg", tostring(job.file.url))
		return nil, nil
	end

	local area, err = ya.image_show(Url(tmp), job.area)
	os.remove(tmp)
	return area, err
end

-- See the design note at the top of this file for why this is built the
-- way it is. $YAZI_VIDEO_MARKER is passed in as an env var.
local WATCHDOG = [[
yazi_pid="$PPID"
(
	printf '\033_Gq=2,a=d,d=A\033\\'

	mpv "$@" 2>/dev/null &
	mpid=$!

	# SIGTERM first, SIGKILL only as a fallback if it doesn't respond
	# quickly. SIGKILL gives mpv no chance to clean up its own terminal
	# state -- confirmed (~56ms typical) it exits promptly on SIGTERM, so
	# there's little cost to preferring it. This mattered for more than
	# the cursor-position issue already noted above: mpv negotiates a
	# kitty keyboard-protocol mode with the terminal for precise key
	# reporting, and SIGKILL was skipping whatever it does to release that
	# on exit -- observed live as yazi's own keyboard input (specifically
	# entering search) breaking after a video had been playing.
	stop_mpv() {
		kill -TERM "$mpid" 2>/dev/null
		i=0
		while [ "$i" -lt 6 ]; do
			kill -0 "$mpid" 2>/dev/null || return 0
			sleep 0.05
			i=$((i + 1))
		done
		kill -9 "$mpid" 2>/dev/null
	}

	trap 'stop_mpv; exit 0' TERM INT

	tmp="$YAZI_VIDEO_MARKER.$$"
	echo "$$" > "$tmp" && mv -f "$tmp" "$YAZI_VIDEO_MARKER"

	superseded_by_video=0
	while kill -0 "$yazi_pid" 2>/dev/null && kill -0 "$mpid" 2>/dev/null; do
		current=$(cat "$YAZI_VIDEO_MARKER" 2>/dev/null)
		if [ "$current" = "$$" ]; then
			sleep 0.1
			continue
		fi
		[ -n "$current" ] && superseded_by_video=1
		break
	done
	stop_mpv
	if [ "$superseded_by_video" != "1" ]; then
		printf '\033_Gq=2,a=d,d=A\033\\\033[H'
	fi
) &
disown 2>/dev/null
]]

function M:peek(job)
	-- job.file.path, not job.file.url -- see the note on extract_thumbnail
	-- for why, and also just more correct here: two different search
	-- queries wrapping the same underlying file should count as "the same
	-- file already playing", which comparing the raw url wouldn't catch.
	local url = tostring(job.file.path)
	if not set_url(url) then
		return ya.preview_widget(job, nil)
	end

	ya.sleep(0.15)
	if current_url() ~= url then
		-- Scrolled past already; don't bother with ffmpeg/mpv at all.
		return
	end

	-- For swf, everything past this point (priming, mpv) operates on the
	-- transcoded mp4's path instead of the original file -- see SWF
	-- TRANSCODING above. A nil here means not ready yet (still
	-- transcoding, or MAX_CONCURRENT_TRANSCODES is busy): bail quietly,
	-- preload() or a later hover will retry.
	local play_path = url
	if is_swf(job.file.url) then
		local kind
		play_path, kind = transcode_swf(job)
		if not play_path then
			-- No self-retry here on purpose (a previous version emitted a
			-- follow-up "peek" on "busy" and that's suspected -- not fully
			-- confirmed -- to have combined with preload()'s since-removed
			-- eager transcoding to spawn mpv long after the user had
			-- scrolled past a file, matching a real "videos never stop,
			-- multiple playing at once" incident). Just render blank; the
			-- next natural hover (this file or otherwise) tries again.
			return ya.preview_widget(job, nil)
		end

		if kind == "image" then
			-- classify_frames (see SWF TRANSCODING above) decided this
			-- file's timeline is a mostly-static interactive one, not a
			-- real animation -- render its single representative frame
			-- directly, no mpv involved. Still has to run the same
			-- cleanup a genuine "left video" hover transition would (the
			-- ps.sub("hover") handler above never fires it here: is_video()
			-- rightly says .swf counts as video for lifecycle purposes,
			-- but this particular hover isn't spawning mpv, so any
			-- previous file's mpv/watchdog would otherwise be left running
			-- underneath a static frame that never tells it to stop).
			os.remove(MARKER)
			clear_url()
			self.child = nil
			clear_graphics()
			local _, show_err = ya.image_show(Url(play_path), job.area)
			return ya.preview_widget(job, show_err)
		end
	end

	if not job.area or job.area.w == 0 or job.area.h == 0 then
		local _, err = prime(job, play_path)
		return ya.preview_widget(job, err)
	end

	local area, err = prime(job, play_path)
	if not area then
		-- err is nil when extraction itself failed (already logged inside
		-- prime()) vs. a proper Error when ya.image_show failed -- only
		-- the latter needs logging here.
		if err then
			ya.err("video-autoplay", "priming failed", err)
		end
		return ya.preview_widget(job, err)
	end

	-- mpv's --vo-kitty-cols/rows alone tell it the *cell* dimensions to
	-- use, but --vo-kitty-width/height (pixels) default to auto-detecting
	-- the *full terminal's* pixel size if left unset -- combining our
	-- small cell count with the full terminal's pixel size gives mpv an
	-- inflated per-cell pixel density, which is why the video was
	-- rendering larger than the pane instead of scaled to it. Pass both,
	-- computed consistently from the same cell size yazi itself uses.
	local cw, ch = rt.term.cell_size()
	local px_w, px_h = area.w, area.h
	if cw then
		px_w, px_h = math.floor(area.w * cw), math.floor(area.h * ch)
	end

	local sh_args = {
		"-c",
		WATCHDOG,
		"--", -- becomes $0 in the script; args below become $1, $2, ... ("$@")
		"--no-config",
		"--profile=sw-fast",
		"--ao=null",
		"--loop-file=inf",
		"--input-terminal=no",
		"--osc=no",
		"--osd-level=0",
		"--really-quiet", -- silences status line + startup/info text alike
		"--vo=kitty",
		"--vo-kitty-alt-screen=no",
		-- Don't let mpv clear the terminal on its own -- it clears far
		-- more than its own cells, wiping out yazi's own panes.
		"--vo-kitty-config-clear=no",
		("--vo-kitty-cols=%d"):format(area.w),
		("--vo-kitty-rows=%d"):format(area.h),
		("--vo-kitty-width=%d"):format(px_w),
		("--vo-kitty-height=%d"):format(px_h),
		("--vo-kitty-left=%d"):format(area.x + 1), -- 1-indexed per mpv's docs
		("--vo-kitty-top=%d"):format(area.y + 1),
		("--video-aspect-override=%d:%d"):format(px_w, px_h), -- see alignment note up top
		play_path, -- transcoded mp4 for swf, else job.file.path -- not job.file.url, see the note on extract_thumbnail
	}

	local child, spawn_err = Command("sh")
		:arg(sh_args)
		:env("YAZI_VIDEO_MARKER", MARKER)
		:stdin(Command.NULL)
		:stdout(Command.INHERIT)
		:stderr(Command.PIPED)
		:spawn()

	if not child then
		return ya.err("video-autoplay", "spawn failed", spawn_err)
	end

	-- Forces a real async yield point -- see design note 2 at the top of
	-- the file for why this is required, not optional. A short timeout is
	-- enough; we don't need whatever (if anything) comes back.
	child:read_line_with({ timeout = 50 })

	-- Keep this reachable so yazi's kill_on_drop doesn't SIGKILL it out
	-- from under us via GC -- see design note 2 at the top of the file.
	self.child = child

	ya.preview_widget(job, nil)
end

function M:seek() end

-- Backup cleanup path only -- ps.sub("hover") above is the reliable one.
-- Kept because it's cheap and covers the (currently theoretical) case of
-- that subscription itself failing to register.
--
-- Deliberately does NOT kick off swf transcoding here (an earlier version
-- did -- see incident note at top of file). yazi's wildcard preloader
-- rule fires this for every file merely scrolled past, not just the one
-- actually previewed, which made transcoding-on-preload both slow
-- (backlog of multi-second Ruffle+ffmpeg calls for files never even
-- looked at) and suspected to be part of what let mpv end up spawned for
-- files long since scrolled past. transcode_swf() runs lazily from
-- peek() instead, same as real video priming already does elsewhere in
-- this file -- there's no precedent here for preload() doing the actual
-- expensive work for playback, only for cleanup.
function M:preload(job)
	if not is_video(job.file.url) then
		os.remove(MARKER)
		clear_url()
		self.child = nil
		clear_graphics()
	end
	return true
end

return M

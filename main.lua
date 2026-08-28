--- @since 26.1.22
-- Auto-plays mp4/webm/mov/avi/mkv previews (muted, looped) in the preview
-- pane, using mpv's kitty terminal-graphics output driver. Nothing here is
-- actually format-specific beyond the VIDEO_EXTS extension list below --
-- ffmpeg (priming) and mpv (playback) both handle any container either
-- supports, so this list is just "which mimes get routed to this plugin
-- in yazi.toml", not a real functional limit.
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

local VIDEO_EXTS = { mp4 = true, webm = true, mov = true, avi = true, mkv = true }

local function is_video(url)
	local ext = tostring(url):lower():match("%.([%w]+)$")
	return ext ~= nil and VIDEO_EXTS[ext] == true
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
-- same signal. Wrapped in pcall since plugin-load-time ps.sub is a bit
-- unusual and we don't want a failure here to break previewing entirely;
-- if it fails, preload() below still provides partial coverage.
local ok, sub_err = pcall(function()
	ps.sub("hover", function(body)
		local url = body.url and tostring(body.url) or nil
		if url and is_video(url) then
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

-- Extracts a single frame near the start of the video to a temp file via
-- ffmpeg. Forces mjpeg output explicitly (-f) rather than relying on a
-- .jpg extension, since os.tmpname() doesn't give us one.
local function extract_thumbnail(job)
	local tmp = os.tmpname()
	local status = Command("ffmpeg")
		:arg({
			"-y",
			"-loglevel",
			"error",
			"-ss",
			"0",
			"-i",
			tostring(job.file.url),
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
-- ya.preview_widget (yazi-plugin/src/utils/preview.rs) only accepts nil, a
-- renderable (or table of them), or a proper mlua Error userdata -- never
-- a plain Lua string. ya.image_show's own failure already returns a
-- proper Error, safe to hand straight to preview_widget, but a plain
-- string here (e.g. "extraction failed") would make it throw "preview
-- widget must be a renderable element or a table of them" and take the
-- whole peek() down with it -- hit live on a real .mov file that ffmpeg
-- couldn't extract a frame from. So extraction failure logs its own
-- detail via ya.err and returns a plain nil second value, not a string,
-- keeping whatever comes out of this function always safe to hand
-- directly to ya.preview_widget.
local function prime(job)
	local tmp = extract_thumbnail(job)
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
	trap 'kill -9 "$mpid" 2>/dev/null; exit 0' TERM INT

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
	kill -9 "$mpid" 2>/dev/null
	if [ "$superseded_by_video" != "1" ]; then
		printf '\033_Gq=2,a=d,d=A\033\\\033[H'
	fi
) &
disown 2>/dev/null
]]

function M:peek(job)
	local url = tostring(job.file.url)
	if not set_url(url) then
		return ya.preview_widget(job, nil)
	end

	ya.sleep(0.15)
	if current_url() ~= url then
		-- Scrolled past already; don't bother with ffmpeg/mpv at all.
		return
	end

	if not job.area or job.area.w == 0 or job.area.h == 0 then
		local _, err = prime(job)
		return ya.preview_widget(job, err)
	end

	local area, err = prime(job)
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
		-- Speculative fix for an AVI-specific symptom ("No more keyframes
		-- available", or playback stuck on the first frame) reported live
		-- on real files that weren't available to reproduce against here
		-- -- synthetic AVI test files (both a plain remux and a proper
		-- Xvid encode) played and looped cleanly without it, so this
		-- couldn't be directly verified to fix that specific case. Forces
		-- ffmpeg/mpv to regenerate presentation timestamps rather than
		-- trust the container's own, which is a well-known mitigation for
		-- exactly this class of keyframe-index/seek problem on malformed
		-- or looser-muxed containers (more common in AVI than newer
		-- formats) -- and a no-op for files with valid timestamps already,
		-- so safe to apply unconditionally rather than only for .avi.
		"--demuxer-lavf-o=fflags=+genpts",
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
		tostring(job.file.url),
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

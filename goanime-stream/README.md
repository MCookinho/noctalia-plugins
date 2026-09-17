# goanime-stream — true online streaming for the Noctalia GoAnime panel

`goanime-stream` is a tiny Go helper that does what the GoAnime CLI's
interactive **"No download (play online)"** option does, but headlessly:

1. searches the anime on AniDB / AnimeFire / Goyabu,
2. resolves the chosen episode to its **direct stream URL** (the same code path
   GoAnime's own playback uses — `GetVideoURLForEpisodeEnhanced`),
3. launches **mpv on that URL immediately**.

Nothing is ever written to disk. No terminal window, no interactive menus.

## Why it exists

The installed `goanime` binary (v1.8.7) has **no headless stream flag**. Its
"play online" mode only lives inside the interactive TUI, which requires a
terminal (fuzzy pickers built on Bubble Tea) and cannot be scripted. Because
GoAnime's internal packages can only be imported from *inside* the GoAnime
module, this helper is compiled into the module tree by `build.sh` and shipped
as a standalone binary.

## Install

```bash
cd goanime-stream
./build.sh            # installs to ~/.local/bin
# or: ./build.sh /usr/local/bin
```

Requirements: `git`, `go >= 1.27.1` (GoAnime's go.mod), network. The first
build clones GoAnime `v1.8.7` and downloads the module dependencies (includes
playwright-go, so allow a few minutes).

Make sure the install directory is in your `PATH`. The Noctalia panel uses
`goanime-stream` automatically when it finds it; otherwise it falls back to the
temporary-cache streaming mode (download to cache → mpv → delete cache), which
needs no extra tools.

## Usage (manual)

```bash
goanime-stream [--source all|anidb|animefire|goyabu] [--quality QUALITY] "anime name" EPISODE
```

Examples:

```bash
goanime-stream --source animefire --quality 1080p "one piece" 1
goanime-stream "jujutsu kaisen" 24
```

- `--source` defaults to `all` (the three panel sources; SuperFlix is excluded —
  it is browser-gated and interactive).
- `--quality` defaults to `best` (`best`, `worst`, `1080p`, `720p`, `480p`, …).
- mpv opens with the same arguments GoAnime builds for online playback
  (network cache, `Referer`/`User-Agent` for the CDN, HLS flags, window title).

## Uninstall

```bash
rm ~/.local/bin/goanime-stream   # or wherever it was installed
```
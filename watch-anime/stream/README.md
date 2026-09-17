# goanime-stream — true online streaming for the Noctalia Watch Anime panel

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

## Install — automatic from the panel (no manual step)

The helper ships **inside this plugin** (`stream/main.go` + `stream/build.sh`).
The first time you click **Watch** without a `goanime-stream` binary on `PATH`,
the panel compiles it in the background into `<pluginDataDir>/bin` and notifies
you as soon as it is ready:

- needs `git` and `go >= 1.27.1` (GoAnime's go.mod) plus network — the first
  build clones GoAnime `v1.8.7` and downloads the module dependencies (includes
  playwright-go, so allow a few minutes);
- while it compiles, **Watch keeps working** through the temporary-cache mode
  (download to cache → mpv → delete cache);
- after that, Watch streams directly — nothing on disk. The panel prefers a
  `goanime-stream` on `PATH` (e.g. system/`go` installs), then its own copy.

## Install — manual

```bash
cd watch-anime/stream
./build.sh            # installs to ~/.local/bin
# or: ./build.sh /usr/local/bin
```

Make sure the install directory is in your `PATH` (or let the panel keep its
own copy in the plugin data dir).

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

To clear the panel's own copy (auto-built), delete the `bin` folder it created
inside the plugin data directory (visible in the plugin's settings/logs).
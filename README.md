# noctalia-plugins

Plugin source repo for [Noctalia](https://noctalia.codeberg.page) v5. Add this
repository as a plugin source and install the plugins from the shell.

## Add as a source

```sh
noctalia msg plugins source add github git https://github.com/MCookinho/noctalia-plugins
```

Then enable a plugin:

```sh
noctalia msg plugins enable mcookinho/osint-tools
noctalia msg plugins install mcookinho/osint-tools
```

See `noctalia msg plugins --help` for all plugin subcommands.

## Plugins

### OSINT Tools

Dashboard (panel) + launcher provider (`/osint ...`) + bar icon (widget
`mcookinho/osint-tools:bar`) that toggle the dashboard. It gathers publicly
available information about a target and renders it as a **relationship graph**
(hub + rings of platform / entity / person nodes; click a node for details):

- **username** — presence across public platforms, grouped into a graph:
  - *social* — X (Twitter), Instagram, TikTok, Threads, YouTube, Reddit, Twitch,
    Kick, Telegram, Bluesky, Mastodon (multi-instance webfinger), LinkedIn,
    SoundCloud, Vimeo, Dribbble, Behance, Medium, Pinterest, Patreon, OK.ru,
    Rumble, DeviantArt, Flickr
  - *dev & coding* — GitHub, GitLab, Codeberg, Bitbucket, SourceForge, Hacker
    News, Keybase, PyPI, npm, DEV.to, Hashnode
  - *games* — Steam (profile via XML; most-played games when Steam's anonymous
    access allows it)
  - **related people** — GitHub followers, Mastodon following, and accounts
    mentioned in public Instagram posts
- **e-mail** — format check, Gravatar profile, and the gravatar-linked social
  profiles shown as a *linked* ring (email → Gravatar → X/IG/GitHub/YouTube…),
  MX records (DoH)
- **CPF** — brazilian CPF checksum/UF validation
- **phone** — how a brazilian phone types E.164/national, DDD, UF, main city
  for the DDD, region, and line type (mobile / landline / 0800 / company /
  service). Owner/carrier/WhatsApp presence need a paid provider: the card says
  so instead of faking data.

**No API keys are required.** Every source is public and key-free; no third-party
credentials are collected or sent anywhere. Use the tool only for legal and
ethical purposes, and respect local privacy laws (e.g. LGPD).

Open the panel with `Shift+Space` (or your launcher) and type `/osint <query>`,
or just open it via the Noctalia dashboard.

## GoAnime Tools (`mcookinho/goanime-tools`)

Pretty panel around the [GoAnime CLI](https://github.com/alvarorichard/GoAnime),
with a bar icon that opens it.

- **Bar icon** — a `movie` icon in the bar opens the panel with one click
  (add `type = "mcookinho/goanime-tools:open"` as a bar widget, or it ships
  predefined in this setup).
- Type `/goanime <query>` in the launcher to open the panel pre-filled and
  searching.
- **Browse** — search results come from MyAnimeList (Jikan, key-free): poster,
  type, year, score, synopsis, genres. Pick a show to see an episode grid.
- **Episodes** — the full episode list as clickable chips; click one to play
  it (download + player, no terminal).
- **Watch / Download / Download all** — pick source (AllAnime / AnimeFire /
  Goyabu / all) and quality, use single episode, a range (`1-5`) or `all`.
  Everything runs headless in the background.
- History of past searches is stored per-plugin; the downloads folder opens
  automatically when a download starts (toggleable).
- Settings: bar icon glyph, default source, default quality, download folder.

Everything runs from the panel — no terminal windows are opened.
Requires the `goanime` binary and a player (`mpv`) on `PATH`.
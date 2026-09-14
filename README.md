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
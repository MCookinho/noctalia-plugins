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
available information about a target from a:

- **username** — GitHub, GitLab, Hacker News, PyPI, npm, Keybase, Bluesky,
  Mastodon (webfinger) and Telegram (heuristic)
- **e-mail** — format check, Gravatar profile, MX records (DoH), optional
  EmailRep.io reputation
- **CPF** — brazilian CPF checksum/UF validation, optional custom API
- **phone** — brazilian phone parsing (DDD/UF/mobile), optional validation API
  (numverify / apilayer template)

All sources are public and key-free by default. If you configure a third-party
API key, that data is fetched directly from the vendor and subject to their
terms of use. Use the tool only for legal and ethical purposes, and respect
local privacy laws (e.g. LGPD).

Open the panel with `Shift+Space` (or your launcher) and type `/osint <query>`,
or just open it via the Noctalia dashboard.
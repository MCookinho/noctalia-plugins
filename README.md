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

- **username** — GitHub, GitLab, Hacker News, PyPI, npm, Keybase, Bluesky,
  Mastodon (webfinger), Telegram (heuristic) and related people via public
  GitHub followers
- **e-mail** — format check, Gravatar profile, MX records (DoH)
- **CPF** — brazilian CPF checksum/UF validation
- **phone** — brazilian phone parsing (DDD/UF/mobile)

**No API keys are required.** Every source is public and key-free; no third-party
credentials are collected or sent anywhere. Use the tool only for legal and
ethical purposes, and respect local privacy laws (e.g. LGPD).

Open the panel with `Shift+Space` (or your launcher) and type `/osint <query>`,
or just open it via the Noctalia dashboard.
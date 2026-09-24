# AI Agents

An [Omarchy](https://omarchy.org) shell bar widget: one bar icon and one panel
for every AI coding subscription on the machine, plus a switch for which Claude
account the `claude` CLI is signed into.

It combines two existing sources and adds account switching:

| From | What it contributes |
|---|---|
| Omarchy's built-in `omarchy.agents` collectors | Tokens by day and by model, the hero, the self-hiding bar slot, cross-device sync |
| [`ai-usagebar`](https://github.com/akitaonrails/ai-usagebar) (optional) | Pace detail ("57% elapsed · 45pts under"), severities, per-provider chips in the bar, every provider that has no collector |
| new here | Claude account switching on Linux, disabled while a session is running |

Both sources are optional. Without `ai-usagebar` you get the collectors' own
limits; without the collectors you get ai-usagebar's providers and no token
history. The module leaves the bar entirely when neither has anything to say.

## Install

```bash
omarchy plugin add https://github.com/cbrompton/omarchy-ai-agents.git --enable
```

It replaces the built-in Agents widget, so take that one out of the bar:

```bash
omarchy plugin disable omarchy.agents
```

Optional extras:

```bash
# Pace detail and more providers
omarchy pkg aur add ai-usagebar

# Put the account switcher on your PATH (the panel finds it without this)
ln -sf ~/.config/omarchy/plugins/ai-agents/bin/omarchy-claude-account ~/.local/bin/
```

Update with `omarchy plugin update ai-agents`.

### Requirements

- Omarchy with the Quickshell-based `omarchy-shell`
- `python3` for the account switcher
- `secret-tool` and an unlocked login keyring (gnome-keyring, as Omarchy ships)
  for storing inactive Claude accounts. Without them the switch refuses rather
  than falling back to plaintext; usage display still works.

## Data

Two feeds, joined in `Model.js`:

- **`~/.local/state/omarchy/agents/usage/*.json`** — one record per agent,
  written by `omarchy-agent-usage-update`. The only source of token history.
- **`ai-usagebar usage --json`** — every configured provider, with the pace
  sentence and severity the records don't carry.

`anthropic` pairs with the `claude` record and `openai` with `codex`;
everything else keeps its own id and gets a tab of its own. Where both feeds
describe one provider, **limits come from ai-usagebar and history from the
record** — never both for one meter, because two sources would disagree on the
minute and flicker between refreshes.

A provider that has never produced data and is only reporting an error (an
unconfigured API key, say) is hidden rather than shown as a permanently red
tab. One that has data and then errors stays visible with the error.

## Claude account switching

The `claude` CLI keeps exactly one login: `~/.claude/.credentials.json`,
holding a **rotating** refresh token. Two clients pointed at copies of the same
token invalidate each other the first time either refreshes. So an account is
never copied here — it is moved:

1. the outgoing credential is captured into the login keyring under its label;
2. the incoming one is written into the single default slot at mode `0600`;
3. the incoming one's keyring copy is dropped.

Exactly one copy of any lineage exists at any moment. The identity marker
(`oauthAccount` in `~/.claude.json` — uuid, email, org, never a token) moves
with it, so `claude` and the usage collectors report the account that is
actually live. Every switch first archives the credential and identity it is
about to overwrite to `~/.local/share/omarchy/claude-accounts/backups/`
(mode `0700`, archives `0600`, last 10 kept).

This is the design `ai-usagebar`'s own `cli_account.rs` documents and tests.
Only its storage backend is macOS-Keychain-only — on Linux every method
returns *"supported on macOS only"* — which is why this reimplements the
storage rather than the reasoning.

### At rest

An inactive account is a secret in **gnome-keyring** (via `secret-tool`,
attribute `omarchy-claude-account`), not a file. The only plaintext credential
on disk is the active one, at the path and mode Claude Code itself uses. Each
account also gets a `0700` directory under
`~/.local/share/omarchy/claude-accounts/<label>/` holding its identity marker.

If the keyring is locked or missing, the switch refuses and says so rather
than falling back to plaintext.

### When it is disabled

The button greys out whenever a Claude session is live, because moving the
credential out from under a running CLI breaks it. Liveness comes from
`~/.claude/sessions/<pid>.json`: a record is only trusted when its `pid` is
alive **and** its `procStart` matches field 22 of `/proc/<pid>/stat`, so a
crashed run's leftover file cannot block a switch and a reused pid cannot fool
it.

A *busy* session is mid-request; an *idle* one still holds the account open and
will refresh the token on its own schedule. Both block the switch, and the
message says which it is. The helper re-checks at the moment of the switch, so
a session started between the poll and the click is still caught.

Every other reason a button is disabled explains itself in its tooltip: no
stored credential yet, a locked keyring, or an active login with no label (that
last one is refused because it could not be saved before being replaced —
`adopt` it first, or `--force` to discard it).

### Setting up accounts

Accounts are registered from a terminal; the panel only switches between them.
The commands below assume you linked the helper onto your PATH (see Install).
If you didn't, use the full path:
`~/.config/omarchy/plugins/ai-agents/bin/omarchy-claude-account`.

Labels can use letters, digits, `.`, `_` and `-`.

**1. Adopt the account you're already signed into.** Until it has a label, the
switch is disabled: an unnamed login can't be saved before it's replaced.

```bash
omarchy-claude-account adopt work
```

This doesn't sign you in again or move anything. It records the label and the
account's identity (email, org) under
`~/.local/share/omarchy/claude-accounts/work/`, and the credential stays where
`claude` keeps it.

**2. Add a second account.**

```bash
omarchy-claude-account add personal
```

This opens `claude` in a separate config directory, so your current login is
not touched. Run through `/login` with the other account in the browser, then
exit `claude` (`/exit` or Ctrl+D). The new credential goes straight into the
keyring and the plaintext copy is deleted. If the keyring is locked or
`secret-tool` is missing, it stops before opening `claude`.

If `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set in your shell, it is
ignored during this sign-in, so the login actually writes a credential.

**3. Check, then switch.**

```bash
omarchy-claude-account status
omarchy-claude-account switch personal
```

Or open the panel and click the account, or press `a` to cycle. Close every
`claude` session first; the switch is disabled while one is running.

To sign an existing label in again (a revoked or expired login), use
`omarchy-claude-account add personal --relogin`.

### Commands

```bash
omarchy-claude-account status              # who is active, what is switchable
omarchy-claude-account adopt work          # name the login you already use
omarchy-claude-account add personal        # register a second and sign it in
omarchy-claude-account add personal --no-login   # register the slot only
omarchy-claude-account switch personal     # move the login
omarchy-claude-account switch personal --dry-run
omarchy-claude-account forget personal     # remove it and its stored credential
```

`adopt` exists because the first account is always one you are already signed
into; making you log in again to give it a name would throw away a working
credential for nothing.

Switching applies only to Claude. Codex and the rest report usage here but
their logins are untouched.

## Interactions

- Bar icon: left = panel, right = launch agent, middle / scroll = next provider.
- Panel: `h`/`l` switch provider, `j`/`k` scroll, `a` cycle Claude account,
  `r` or Enter refresh, Tab to the neighbouring panel, Esc closes.
- IPC: `omarchy-shell ai-agents <open|close|toggle|refresh|next>`,
  and `account <label>` to switch (or `account ""` to list).

## Settings

In this widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often both feeds regenerate |
| `showValue` | `true` | Show the percentage next to the mark in the bar |
| `showProvider` | `false` | Prefix it with the short code (`cld`, `gpt`) |
| `showAll` | `false` | Show every provider in the bar at once |
| `barWindow` | `"auto"` | Which window the bar shows; auto takes the fullest |
| `accountSwitch` | `true` | Show the Claude account section |
| `syncMode` / `syncDir` / `syncFileName` / `syncDeviceId` | | Cross-device aggregation, as in `omarchy.agents` |

```bash
omarchy bar set ai-agents refreshIntervalSec 300 --json
omarchy bar set ai-agents showAll true --json
```

Per-agent enablement is nested, so pass the whole object:

```bash
omarchy bar set ai-agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": true },
  "fireworks": { "enabled": false }
}' --json
```

## Layout across displays

No font size, column width or row height in the panel is a literal pixel
count. The day chart's two text columns are measured with `TextMetrics` at the
live font against the widest string they can hold (`Today`, `999.9M`), so they
never clip when the font grows. Everything else derives from `Style.space` /
`Style.font` / `Style.spacing`, provider and account chips sit in a `Flow` that
wraps instead of squeezing, and every label either wraps or elides. The panel's
width and height are requests that the host clamps to the actual screen, so it
scrolls rather than overflowing.

Verified at `[font] base-size` 10 and 18, in both light and dark themes.

## Files

```
Panel.qml     bar button, popup, and every row component
Main.qml      discovery, both feeds, cross-device sync
Agent.qml     one record's file watcher
Accounts.qml  account state; runs the helper, parses its JSON
Model.js      the merge, formatting, and the blocked-reason rules — pure, testable
bin/omarchy-claude-account   the switch itself
test/test-switch.py          exercises the credential move against a throwaway HOME
```

## Uninstall

```bash
omarchy plugin remove ai-agents
omarchy bar put omarchy.agents --section right   # bring the built-in back
rm -f ~/.local/bin/omarchy-claude-account
```

Stored Claude accounts stay in the keyring and in
`~/.local/share/omarchy/claude-accounts/`; run
`omarchy-claude-account forget <label>` for each one first if you want them gone.

## Tests

```bash
python3 test/test-switch.py
```

Runs the credential move against a throwaway `HOME`, using test-only keyring
entries that it removes afterwards. Your real login is never touched.

## License

MIT

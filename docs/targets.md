# Targets

A target is somewhere VeeamAware sends notifications. The installer adds and removes them for you; this page covers the details and what you can set by hand in `config\config.json`.

**On this page:** [Target types](#target-types) · [Options for every target](#options-for-every-target) · [More than one channel](#more-than-one-channel) · [Discord](#discord) · [Microsoft Teams](#microsoft-teams) · [Generic webhook](#generic-webhook) · [Testing](#testing)

## Target types

| Type | What it does |
|---|---|
| `discord` | Embeds with status badges, coloured tables, mentions, threads |
| `teams` | An Adaptive Card in a Teams channel. Times show in each reader's time zone. |
| `webhook` | POSTs the event as JSON to any URL: n8n, Home Assistant, Power Automate, your own API |
| *plugins* | Any `.ps1` in `plugins\targets\`. See [Writing a target](writing-a-target.md). |

The top-level `discord` block in the config is the target named `discord`. Every other target goes under `"targets": [...]`. The examples in `config.example.json` ship disabled.

## Options for every target

| Option | Default | Notes |
|---|---|---|
| `minSeverity` | `info` | `info` / `warning` / `critical` |
| `kinds` | `["*"]` | Any of `session`, `malware`, `repository`, `analyzer`, `authorization`, `health`, `digest` |
| `includeResolved` | `true` | Send "problem cleared" events |
| `includeDeferred` | `false` | Also send sessions that routing sends to the digest, as they finish |
| `enabled` | `true` | |

## More than one channel

Add as many targets as you like, of any type, each with a unique `name`. For example, a second Discord channel that only gets failures and pings the on-call role:

```json
"targets": [
  { "type": "discord", "name": "oncall", "webhookUrl": "https://discord.com/api/webhooks/…",
    "minSeverity": "critical", "username": "Backup alerts",
    "mentions": { "onFailure": ["<@&123456789012345678>"] } }
]
```

To send a digest to just one channel, list its name in the digest's `targets` (see [Digests](configuration.md#digests)).

## Discord

Create the webhook in Discord: channel settings → **Integrations** → **Webhooks** → **New Webhook**, then copy its URL.

Every `discord.*` setting also works on a Discord entry in `targets`, so each channel can be set up separately: `threadId`, `username`, `avatarUrl`, `mentions`, `statusBadges`, `ansiColors`. See [Common settings](configuration.md#common-settings).

### Mentions

Discord only notifies people loudly when they're mentioned. Each Discord target can ping on failures, warnings, successes and security alerts (malware, analyzer findings, four-eyes requests):

```json
"mentions": { "onFailure": ["<@&123456789012345678>"], "onSecurity": ["<@&123456789012345678>", "@here"] }
```

- `<@&id>` is a role, `<@id>` a user; `@here` and `@everyone` work too. To get an id, turn on Developer Mode in Discord, then right-click the role or user → **Copy ID**.
- The installer asks for failure and security mentions when you add a Discord target. Re-run it and choose **Targets → m** to change them.
- A routing rule can add more for its own jobs. See [Routing](configuration.md#routing).

## Microsoft Teams

1. In Teams, open the channel's **⋯** menu, choose **Workflows**, then **Post to a channel when a webhook request is received**. Finish the wizard and copy the URL.
2. Add it with the installer, or by hand: `{ "type": "teams", "name": "teams", "url": "https://…", "minSeverity": "warning" }`
3. Run `C:\VeeamAware\Test-VeeamAwareTarget.ps1 -Target teams`.

Workflow webhooks can't @mention people, so Teams has no `mentions` option. Long reports are shortened to fit Teams' 28 KB limit.

## Generic webhook

```json
{ "type": "webhook", "name": "n8n", "url": "https://n8n.example.com/webhook/veeam",
  "minSeverity": "warning", "tokenFile": "secrets\\n8n-token.json", "signingSecretFile": "secrets\\n8n-hmac.json",
  "headers": { "X-Env": "prod" } }
```

Store the token and signing secret with `C:\VeeamAware\Set-VeeamAwareSecret.ps1 -Path secrets\n8n-token.json`. They're encrypted with DPAPI and can only be read on this machine.

### The event body

Each request's body is one event (`veeamaware.event/v1`):

- `schema` and `id`
- `kind`: `session` / `malware` / `repository` / `analyzer` / `authorization` / `health` / `digest` / `test`
- `severity`: `info` / `success` / `warning` / `critical`
- `status`, `title`, `text` (plain) and `markdown`
- `fingerprint`: a stable key for "the same problem", e.g. `vbr/<server>/job/<jobId>`
- `resolved`, `deferred`, `occurredAt` and `source`
- `details`: structured data such as per-object results, byte counts and repository space
- `report`: the neutral layout that chat targets render (`veeamaware.report/v1`). It can be `null`.

### Headers

- `X-VeeamAware-Event: <kind>` and `X-VeeamAware-Delivery: <id>` on every request
- `Authorization: Bearer …` with `tokenFile`
- `X-VeeamAware-Signature: sha256=<hex HMAC-SHA256 of the raw body>` with `signingSecretFile`

Deliveries are retried on 429 and 5xx, and one failing target never blocks the others.

## Testing

```powershell
C:\VeeamAware\Test-VeeamAwareTarget.ps1                   # a test message to every target
C:\VeeamAware\Test-VeeamAwareTarget.ps1 -Target oncall    # just one
C:\VeeamAware\Test-VeeamAwareTarget.ps1 -WhatIf           # print the payloads instead of sending
C:\VeeamAware\Test-VeeamAwareTarget.ps1 -ListTypes        # installed types, and any plugin that failed to load
pwsh -File C:\VeeamAware\tools\New-SampleCards.ps1 -Send  # every kind of card, with made-up data
```

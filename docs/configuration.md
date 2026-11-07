# Configuration

Most settings are easiest to change with the installer: run `C:\VeeamAware\Install-VeeamAware.ps1` again and pick what to change. This page covers everything in `config\config.json`, including what the installer doesn't ask about.

`config\config.json` is created from [`config\config.example.json`](../config/config.example.json) on first install. Any key you leave out uses its default. Your own edits are kept when you re-run the installer.

**On this page:** [Common settings](#common-settings) · [Routing](#routing) · [Digests](#digests) · [Data sources](#data-sources)

Related: [Targets](targets.md) · [Server health](server-health.md)

## Common settings

| Key | Default | Notes |
|---|---|---|
| `discord.webhookUrl` | — | Leave empty if you only use other targets |
| `discord.threadId` | `""` | Post into a thread or forum post |
| `discord.mentions.onFailure` / `onWarning` / `onSuccess` / `onSecurity` | `[]` | e.g. `["<@123>", "<@&456>"]` (user, role) |
| `discord.statusBadges` | `true` | A small coloured status badge as each report's thumbnail |
| `discord.ansiColors` | `true` | Coloured tables on Discord desktop and web. Mobile shows them plain. |
| `notifications.objectDetail` | `all` | `all` / `problems` / `none`: the per-object table on job reports |
| `watch.intervalMinutes` | `5` | Re-run `Install-VeeamAware.ps1` after changing it |
| `watch.repositories.warnPercentFree` / `criticalPercentFree` | `15` / `5` | |
| `watch.repositories.exclude` | `[]` | Repository names, wildcards allowed |
| `watch.health.*` | | See [Server health](server-health.md) |
| `vbr.dataSource` | `auto` | See [Data sources](#data-sources) |
| `vbr.port` | `443` | REST only. Use `9419` on 13.0.x. |
| `update.channel` | `stable` | `stable` / `preview` |
| `update.notify` | `true` | Mention new releases in the digest |
| `logging.level` | `Info` | `Debug` logs every Veeam call |

## Routing

Routing decides, per job, whether a finished session is reported right away, saved for the digest, both, or not at all. The installer sets up a rule for agent jobs; add your own under `routing.rules`.

- Rules are checked in order, and the first match wins.
- Each result (`success`, `warning`, `failure`) maps to `immediate`, `digest`, `both` or `off`.
- A job no rule matches is reported immediately.

```json
"routing": { "rules": [
  { "name": "Agents: failures now, the rest in the digest",
    "match": { "jobTypes": ["AgentBackup", "AgentPolicy"] },
    "success": "digest", "warning": "digest", "failure": "immediate" },
  { "name": "Lab jobs: digest only",
    "match": { "jobs": ["LAB-*"] },
    "success": "digest", "warning": "digest", "failure": "digest" },
  { "name": "Everything else",
    "match": { "jobs": ["*"] },
    "success": "immediate", "warning": "immediate", "failure": "immediate" }
]}
```

`match` takes:
- `jobs`: job names, wildcards allowed
- `jobTypes`: e.g. `BackupJob`, `BackupCopyJob`, `ReplicaJob`, `AgentBackup`, `AgentPolicy`
- `exclude`: job names to skip

## Digests

Each entry in `digests` is a separate summary with its own schedule, jobs, sections and targets. The installer sets up one called `daily`.

```json
"digests": [
  { "name": "daily", "schedule": { "every": "day", "at": "08:00" }, "targets": ["*"],
    "jobs": { "include": ["*"] }, "sections": ["agents", "jobs", "repositories", "security"] },
  { "name": "weekly-management", "schedule": { "every": "week", "day": "Monday", "at": "09:00" },
    "targets": ["teams"], "sections": ["jobs", "repositories"], "skipWhenEmpty": true }
]
```

| Key | Notes |
|---|---|
| `schedule` | `every`: `day` or `week` (then also `day`), and `at` (local time, HH:mm) |
| `targets` | Target names, or `*` for all |
| `jobs` | `include`, `exclude`, `jobTypes`, same as routing `match` |
| `content` | `all` (every session) or `routed` (only sessions routed to `digest` or `both`) |
| `sections` | Any of `agents`, `jobs`, `repositories`, `security` |
| `skipWhenEmpty` | Don't send a digest with nothing in it |

The watcher sends each digest when it's due, so schedule changes need no reinstall. To preview one without sending it:

```powershell
C:\VeeamAware\Invoke-VeeamAwareDigest.ps1 -Name daily -WhatIf
```

## Data sources

`vbr.dataSource` decides how VeeamAware reads VBR:

| Value | Reads through | Use for |
|---|---|---|
| `auto` (default) | REST when a credential is stored and the API serves data, otherwise PowerShell | Most installs |
| `powershell` | Veeam's local `Veeam.Backup.PowerShell` module. No stored credential. | **Community Edition**, whose REST API answers data calls with `License restrictions apply.` |
| `rest` | The VBR REST API (1.3-revN) with a stored VBR account | Licensed editions. Run `Install-VeeamAware.ps1 -UseRest` to store the account. |

**REST permissions.** A dedicated account with the *Veeam Backup Viewer* role covers job reports, sessions and repositories. Malware, analyzer and four-eyes events may need *Security Administrator*. Anything the role can't read is logged and skipped.

**PowerShell profiles.** The PowerShell source reads some properties Veeam doesn't document, such as session progress, backup statistics and repository containers. Their names live in versioned profiles in `src\Profiles\PowerShell\`, not in the code:

- `13.0.psd1` is the base for every 13.x build. Profiles at or below the installed module's version are merged in order.
- A new VBR build needs only a new file (`13.2.psd1`, `14.0.psd1`…) with the keys that changed. Each field also lists fallback names, so small renames need no new profile.
- `vbr.powershellProfile` points at a local `.psd1` that is merged last. Use it to fix a property on your server without editing code.
- `tools\Probe-VeeamPowerShell.ps1` dumps the real property names on a server. A new profile is written from that output.

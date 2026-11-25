# VeeamAware

[![tests](https://github.com/inspirenxe/veeamaware/actions/workflows/tests.yml/badge.svg)](https://github.com/inspirenxe/veeamaware/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Notifications for **Veeam Backup & Replication v13** on Windows, sent to **Discord**, **Microsoft Teams** or any **JSON webhook**.

- Works on **Community Edition**, with nothing extra to install: VBR 13 already has everything it needs.
- Never slows down or fails a backup job.
- Says *why* a job failed, not just that it did.

For example, an agent backup that fails after a VBR upgrade because the agent on that machine is out of date:

<table>
<tr><th>Discord</th><th>Microsoft Teams</th></tr>
<tr>
<td valign="top"><img src="docs/images/failure-discord.png" alt="Failed agent backup in Discord: 3rd failure in a row, the error, agent 13.1.0.411 out of date, and how to upgrade it" width="420"></td>
<td valign="top"><img src="docs/images/failure-teams.png" alt="The same failed agent backup as a Teams Adaptive Card" width="420"></td>
</tr>
</table>

> Version 0.1.0. It runs daily on a Community Edition server, but much hasn't been tried on other setups yet; see [Project status](#project-status).

VeeamAware is an independent community project. It isn't affiliated with, endorsed by or supported by Veeam Software. Veeam and Veeam Backup & Replication are trademarks of Veeam Software.

**Contents:** [What it sends](#what-it-sends) · [Install](#install) · [Everyday use](#everyday-use) · [How it works](#how-it-works) ·
[Troubleshooting](#troubleshooting) · [Project status](#project-status) · [Security](#security) · [How it's made](#how-its-made) · [License](#license)

**Reference:** [Configuration](docs/configuration.md) · [Targets](docs/targets.md) · [Server health](docs/server-health.md) · [Writing a target](docs/writing-a-target.md)

## What it sends

| Notification | Sent |
|---|---|
| **Job report**: result, data transferred, duration compared with the usual run, each object, errors and warnings, recent history, repository space | When the job ends |
| **Failures and warnings** of any job, including Veeam Agent jobs and policies | Right away or in the digest, your choice per job ([routing](docs/configuration.md#routing)) |
| **Digest**: what needs attention, every job's last 7 days, storage, security | Daily at 08:00 by default ([digests](docs/configuration.md#digests)) |
| **Repository** low on space, offline, or recovered | Within a few minutes |
| **Malware detection** | Within a few minutes |
| **Server health**: a Veeam service stopped, a job stuck, the watcher failing, VBR updated. Quiet during Veeam upgrades; something that keeps going down and up sends one "flapping" card instead of every change. | Within a few minutes ([server health](docs/server-health.md)) |
| **Security & Compliance Analyzer** findings | After each analyzer run |
| **Four-eyes** approval requests (licensed editions) | Within a few minutes |

On Discord, failures and security alerts can ping a role or person, per channel and per job ([mentions](docs/targets.md#mentions)).

Click a card type to see it. Every name, address and number in these is made up.

<details>
<summary><b>Successful job</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/success-discord.png" alt="Successful backup job in Discord" width="420"> | <img src="docs/images/success-teams.png" alt="Successful backup job in Teams" width="420"> |
</details>

<details>
<summary><b>Job with warnings</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/warning-discord.png" alt="Backup job with warnings in Discord" width="420"> | <img src="docs/images/warning-teams.png" alt="Backup job with warnings in Teams" width="420"> |
</details>

<details>
<summary><b>Daily digest</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/digest-discord.png" alt="Daily digest in Discord" width="420"> | <img src="docs/images/digest-teams.png" alt="Daily digest in Teams" width="420"> |
</details>

<details>
<summary><b>Repository low on space</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/repository-discord.png" alt="Repository critically low on space in Discord" width="420"> | <img src="docs/images/repository-teams.png" alt="Repository critically low on space in Teams" width="420"> |
</details>

<details>
<summary><b>Malware detection</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/malware-discord.png" alt="Malware detection in Discord" width="420"> | <img src="docs/images/malware-teams.png" alt="Malware detection in Teams" width="420"> |
</details>

<details>
<summary><b>Veeam service stopped</b></summary>

| Discord | Teams |
|---|---|
| <img src="docs/images/service-discord.png" alt="Veeam service stopped in Discord" width="420"> | <img src="docs/images/service-teams.png" alt="Veeam service stopped in Teams" width="420"> |
</details>

## Install

### Before you start

You need:
- **VBR 13.0 or 13.1 on Windows.** Tested on 13.1.0.411, 13.1.1.700 and 13.1.2.57, Community Edition.
- **A webhook URL** for each place you want notifications:
  - **Discord:** channel settings → Integrations → Webhooks → New Webhook → copy the URL.
  - **Teams:** the channel's **⋯** menu → Workflows → *Post to a channel when a webhook request is received* → copy the URL.
  - **Anything else:** a URL that accepts a JSON POST.

You don't need to install PowerShell 7: VBR 13 already did.

### 1. Run the installer

On the VBR server, open PowerShell **as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/inspirenxe/veeamaware/main/install.ps1 | iex
```

It downloads VeeamAware to `C:\VeeamAware` and asks a few questions:

1. **Where to send notifications.** Paste each webhook URL and choose what it gets: everything, warnings and failures, or failures only. You can add more later.
2. **Server health alerts.** On or off, and how long a problem must last before you're told. Enter accepts the defaults.
3. **The daily digest.** When to send it.
4. **Agent jobs.** Whether their results arrive right away or in the digest.

Then it checks that it can read VBR, sends a test message to each place you added, and sets up a scheduled task that checks VBR every 5 minutes.

### 2. Attach the post-job hook

The scheduled task already catches every job within a few minutes. To get reports the moment a job ends, attach the hook. The installer offers to do this at the end, or run:

```powershell
C:\VeeamAware\Register-VeeamAwareJob.ps1          # see which jobs it would change
C:\VeeamAware\Register-VeeamAwareJob.ps1 -Apply   # attach it to VM, copy and file jobs
```

Agent jobs keep their scripts per job, so for those it prints the command to paste in. Agent policies can't run scripts at all; the scheduled task reports them.

A job that already runs a post-job script of its own is left alone. With `-Overwrite` the hook replaces it, the old script is saved in `state\replaced-post-job-scripts.json`, and `-Remove` (or the uninstaller) puts it back.

### 3. Check it works

You should already have a test message in each channel. To see every kind of card, with made-up data:

```powershell
pwsh -File C:\VeeamAware\tools\New-SampleCards.ps1 -Send
```

<details>
<summary>Other ways to install</summary>

**Preview releases or another folder.** Run the one-liner as a script block to pass options:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/inspirenxe/veeamaware/main/install.ps1))) -Channel preview -Path D:\VeeamAware
```

**Unattended.** Pass targets as `type[:name][@severity]=url`:

```powershell
.\Install-VeeamAware.ps1 -NoPrompt -Target discord=https://discord.com/api/webhooks/…, teams:ops@warning=https://…
```

Through the one-liner, put these in `-InstallerArguments`.

**From a zip.** Download a release from [Releases](https://github.com/inspirenxe/veeamaware/releases), extract it, run `Get-ChildItem -Recurse | Unblock-File`, then `.\Install-VeeamAware.ps1` from PowerShell 7.

**With a VBR account (licensed editions).** `.\Install-VeeamAware.ps1 -UseRest` stores an account for the REST API. See [Data sources](docs/configuration.md#data-sources).
</details>

## Everyday use

### Change settings

Run the installer again. It shows what is set now; pick a number to change it, or press Enter to keep everything.

```powershell
C:\VeeamAware\Install-VeeamAware.ps1
```

```text
    1  Targets        discord, oncall, teams
    2  Health alerts  on, alert after 15 min, repeat every 1 h
    3  Digest         'daily' daily at 08:00
    4  Agent jobs     failures right away, the rest in the digest
    5  Watcher        every 5 min
    6  Data source    auto
    7  Updates        stable channel
    8  Post-job hook  review, attach or remove

Change which (number, or Enter to save and finish):
```

For anything the installer doesn't ask about, edit `C:\VeeamAware\config\config.json`. See [Configuration](docs/configuration.md).

### Update

The digest tells you when a new release is out.

```powershell
C:\VeeamAware\Update-VeeamAware.ps1 -Check             # see what's available
C:\VeeamAware\Update-VeeamAware.ps1                    # install the newest release
C:\VeeamAware\Update-VeeamAware.ps1 -Channel preview   # switch to preview releases too
C:\VeeamAware\Update-VeeamAware.ps1 -Tag v0.1.0        # install a specific release, e.g. to go back
```

Updates keep your settings, secrets, state, logs and plugins.

### Pause alerts for planned work

Veeam upgrades are detected on their own. For other work, such as Windows updates:

```powershell
C:\VeeamAware\Set-VeeamAwareMaintenance.ps1 -Minutes 120 -Reason 'Windows updates'
C:\VeeamAware\Set-VeeamAwareMaintenance.ps1 -Off
```

This pauses server health alerts only. Job reports still go out.

### Uninstall

```powershell
C:\VeeamAware\Uninstall-VeeamAware.ps1                # remove the hook and the scheduled task; keep C:\VeeamAware
C:\VeeamAware\Uninstall-VeeamAware.ps1 -RemoveFiles   # also delete C:\VeeamAware, including settings and secrets
```

It removes the hook only where it runs `VeeamAware.ps1`, and leaves other scripts alone. It lists the jobs it can't change, such as agent jobs, for you to check by hand. If it can't reach VBR to remove the hook, `-RemoveFiles` keeps the folder, since jobs still pointing at a deleted script would warn on every run; add `-Force` to delete it anyway.

## How it works

- **The post-job hook** starts a background worker and exits at once, so it can't delay or fail a job. The worker waits for the session to finish, then sends the report.
- **The scheduled task** runs every 5 minutes as SYSTEM. It reports any session the hook didn't, checks repositories, malware events, the analyzer and server health, and sends digests when they're due.
- **Nothing is sent twice.** The hook and the task share a record of what has been reported.
- **One report, many targets.** Each notification is built once, then drawn the right way for each target.

VeeamAware reads VBR through Veeam's own PowerShell module, which works on Community Edition. Licensed editions can use the REST API instead. See [Data sources](docs/configuration.md#data-sources).

## Troubleshooting

Logs are in `C:\VeeamAware\logs\`: `hook-*`, `session-*`, `watch-*` and `digest-*`. For more detail, set `"logging": { "level": "Debug" }` in the config.

```powershell
cd C:\VeeamAware
.\Test-VeeamAwareTarget.ps1                             # send a test message to every target
.\Invoke-VeeamAwareSession.ps1 -JobId <guid> -WhatIf    # show the report for a job's latest session
.\Invoke-VeeamAwareSession.ps1 -SessionId <guid> -Force # send a session's report again
.\Invoke-VeeamAwareDigest.ps1 -Name daily -WhatIf       # show today's digest without sending it
.\Invoke-VeeamAwareWatch.ps1 -WhatIf                    # show what the scheduled task would send
```

To find a job's GUID: `(Get-VBRJob -Name 'My Job').Id`, or `Get-VBRComputerBackupJob` for agent jobs.

Still stuck? [Open an issue](https://github.com/inspirenxe/veeamaware/issues/new/choose). The bug template lists what to include.

## Project status

What has been run against a real server so far:

| Area | Status |
|---|---|
| Discord, PowerShell data source, Community Edition 13.1 | In daily use |
| Microsoft Teams | Tested: connection card, job report, digest |
| Server health | Service outages, reminders and recovery, stuck sessions, watcher failures, and a real VBR 13 upgrade from the ISO, tested live. Flapping only in the offline tests. |
| Generic webhook | Offline tests only (payload, headers, signing) |
| REST data source on a licensed edition | Built against the documented API, not yet tried on a licensed server |
| VBR 13.0.x | Should work, but not yet tried on a real 13.0 server. If something is blank or wrong, attach the output of `tools\Probe-VeeamPowerShell.ps1` to an issue. |

Reports from other setups are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

- Webhook URLs are secrets: anyone who has one can post to your channel. The installer limits VeeamAware's folders to SYSTEM and Administrators.
- Stored passwords and tokens are encrypted with DPAPI and can only be read on this machine.
- Plugins run as SYSTEM, so only add ones you trust.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## How it's made

VeeamAware is built with AI assistance. Its code, tests and documentation are written with
[Claude Code](https://claude.com/claude-code), Anthropic's coding agent, under the maintainer's direction: they
decide what goes in and try it out on a real VBR server. Every commit says so with a `Co-Authored-By: Claude`
trailer.

The screenshots above are rebuilt from made-up data with `tools\New-ReadmeImages.ps1`. Teams cards are drawn by Microsoft's Adaptive Cards renderer; the Discord layout is a close imitation, since Discord has no public renderer.

## License

VeeamAware is MIT-licensed, © 2026 InspireNXE. See [LICENSE](LICENSE).

It runs on PowerShell 7 and Veeam's own `Veeam.Backup.PowerShell` module, both installed by VBR 13. The screenshot tool
loads Microsoft's [Adaptive Cards](https://adaptivecards.io/) renderer (MIT) and [Twemoji](https://github.com/jdecked/twemoji)
(CC-BY 4.0); VeeamAware itself doesn't use them.

VeeamAware takes its cue from tigattack's [VeeamNotify](https://github.com/tigattack/VeeamNotify), which is GPL-licensed.
It was written from scratch for v13, from VBR's documented interfaces and its own testing, and contains none of
VeeamNotify's code.

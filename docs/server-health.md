# Server health

Besides job reports, the watcher checks the backup server itself every few minutes: Veeam services that have stopped, jobs that appear stuck, and the watcher failing. The installer asks whether you want these alerts and how they're timed.

**On this page:** [Alert timing](#alert-timing) · [What is checked](#what-is-checked) · [During Veeam upgrades](#during-veeam-upgrades) · [Maintenance mode](#maintenance-mode)

Health events have kind `health`, so a [target](targets.md) can take or skip them with `kinds`. Digests add a line when a service is down, the watcher is failing, or maintenance mode is on.

## Alert timing

Three timings apply to every check. They live under `watch.health`, and any check can override them, for example `watch.health.services.repeatEveryMinutes`.

| Setting | Default | Meaning |
|---|---|---|
| `firstAlertAfterMinutes` | `15` | How long a problem must last before the first alert. Hides reboots and service restarts. |
| `repeatEveryMinutes` | `60` | How often to remind you while it lasts. `0` alerts once. |
| `backUpForMinutes` | `5` | How long a service must run again before "running again" is sent. |

## Flapping

Something that keeps going wrong and coming back, like a service that crashes every half hour or a repository hovering on a free-space threshold, would otherwise send a card every time it changes. Instead:

- After 4 changes (alerts or recoveries; reminders don't count) within 60 minutes, one **Flapping** card goes out and further cards for it are held.
- Once it has stayed the same for 30 minutes, one **Settled** card says how it ended up: OK, or still a problem. This is checked on every watcher run, including runs that fail because VBR is down.
- Only delivered cards count as changes, so an outage while Discord or Teams is unreachable isn't mistaken for flapping.

This covers services, the watcher and repositories. Settings under `watch.flapping`: `enabled`, `changes`, `withinMinutes`, `settleMinutes`.

## What is checked

| Check | Alerts when | Settings (`watch.health.…`) |
|---|---|---|
| **Services** | A watched service has been stopped for `firstAlertAfterMinutes` | `include`, `exclude`, `required`, `notifyRecovery` |
| **Stuck sessions** | A session runs far longer than usual, or its progress stops moving | `sessions.*` |
| **Watcher** | The watcher fails 3 runs in a row, for example when VBR is unreachable | `watcher.failureAlertAfter`, `notifyRecovery` |
| **VBR updated** | VBR's version changed since the last pass (information only) | `upgrade.notifyVersionChange` |

### Services

- Watched: automatic-start services matching `include` (`Veeam*`, `postgresql*`, `MSSQL$VEEAMSQL*`, by name or display name), plus `required` (`VeeamBackupSvc`), which is reported as *Missing* if it disappears.
- One alert lists every stopped service, with the reason Windows logged. Reminders follow while any stays down.
- "Running again" goes out once they have all run for `backUpForMinutes`. A service that drops again inside that window counts as the same outage.

### Stuck sessions

- A session is stuck when it has run 3× longer than the job usually takes (`usualFactor`), or its progress hasn't moved for 4 hours (`noProgressMinutes`).
- Never before 2 hours (`minHours`), and 12 hours for a job with no history (`hours`).
- Per-job limits: `jobs`, e.g. `[{ "job": "File server*", "hours": 24 }]`. These apply as given, even under `minHours`. Skip jobs with `excludeJobs`.
- Backup copy and idle sessions are skipped, since they stay open by design.
- The alert shares the job's fingerprint, so the job's own report resolves it.

### Watcher

- Failures while services are down or Veeam is upgrading don't count.
- If the scheduled task stops running altogether, the next post-job hook reports it, once a day.

## During Veeam upgrades

You don't need to do anything when you upgrade VBR: health alerts pause on their own while a Veeam installer runs. VeeamAware treats these as an installer:

- a process named like one in `upgrade.processNames`
- `msiexec` or a setup process whose path or command line mentions Veeam
- a setup-like program published by Veeam, or anything started from a CD/ISO drive. This covers `Setup.exe` on a mounted VBR ISO.
- Windows Installer busy (an install in progress, or its service running), but only while Veeam services are down

The Veeam Updater processes that always run never count.

While an installer runs:
- The watcher skips its VBR checks and digests, so it never loads Veeam's PowerShell module while files are being replaced. It catches up on the next run.
- Alerts stay paused until `upgrade.quietMinutes` (30) after the installer finishes or VBR's version changes. The service timers then start over.
- A signal that lasts longer than `upgrade.maxHours` (6) stops pausing alerts, so a lookalike process can't silence them for good.

To see what VeeamAware detects, run `tools\Probe-Health.ps1 -NoVbr` during an upgrade. It doesn't touch VBR.

## Maintenance mode

For other planned work, pause health alerts by hand. Job reports and the other alerts still go out.

```powershell
C:\VeeamAware\Set-VeeamAwareMaintenance.ps1 -Minutes 120 -Reason 'Windows updates'
C:\VeeamAware\Set-VeeamAwareMaintenance.ps1 -Off
C:\VeeamAware\Set-VeeamAwareMaintenance.ps1          # show the current state
```

To see every health card without waiting for a real outage, run `tools\Send-HealthPreview.ps1`. It posts samples titled `[Preview]` that mention nobody, and changes nothing.

To try the stuck-job and watcher alerts for real, end to end:

```powershell
pwsh -File C:\VeeamAware\tools\Test-LiveAlerts.ps1 -Stuck 'Some Job'   # that job counts as stuck after 3 minutes; start it in VBR
pwsh -File C:\VeeamAware\tools\Test-LiveAlerts.ps1 -Watcher            # every watcher run fails until -Stop
pwsh -File C:\VeeamAware\tools\Test-LiveAlerts.ps1 -Stop               # put back the settings the test changed (your other edits stay)
```

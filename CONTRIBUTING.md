# Contributing

Thanks for helping. Bug reports from servers other than the ones already tested are especially useful: other VBR builds, licensed editions, other repository types, scale-out repositories, large job counts.

## Reporting a problem

Please include:

- VBR version and edition (Help → About), and the Veeam module version: `(Get-Module Veeam.Backup.PowerShell -ListAvailable).Version`
- VeeamAware version: the footer of any message, or `src\VeeamAware.psm1`
- The relevant lines from `logs\`. Set `"logging": { "level": "Debug" }` and reproduce if you can.
- For a wrong or missing value in a report: the output of `tools\Probe-VeeamPowerShell.ps1`. It is read-only and writes `tools\probe-output.txt`.

**Remove webhook URLs, server names and anything else private before you post.** Logs can contain job, server and repository names.

## Development

You don't need a Veeam server for most work. The offline tests use mock Veeam data:

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

They run on Windows (secrets use DPAPI) and in CI on every push. Set `VEEAMAWARE_TEST_WEBHOOK` to a Discord webhook to also post sample messages.

On a VBR server, `-WhatIf` on any `Invoke-*` script prints the payloads instead of sending them.

### Layout

| Path | What |
|---|---|
| `VeeamAware.ps1` | Post-job hook: starts the worker and exits at once |
| `Invoke-VeeamAware*.ps1` | Session worker, watcher, digest |
| `src\Source.ps1`, `Rest.ps1`, `PSProvider.ps1` | Data sources. The PowerShell provider reads property names from `src\Profiles\PowerShell\*.psd1`. |
| `src\Report.ps1` | Builds the neutral reports (`veeamaware.report/v1`) |
| `src\Events.ps1`, `Routing.ps1`, `Targets.ps1` | Events, routing rules and digests, target registry and delivery |
| `src\Targets\` | Built-in targets: Discord, Teams, webhook |
| `src\Update.ps1`, `install.ps1`, `Update-VeeamAware.ps1` | Releases and updates |
| `tests\` | Offline test suite and mocks |
| `tools\` | Read-only probes for new Veeam builds, and the badge generator |

### Guidelines

- **PowerShell 7.2+, strict mode.** Read optional properties with `Get-VAProp`, which returns a default instead of throwing.
- **`install.ps1` must stay Windows PowerShell 5.1-compatible.** It is the one script people run before PowerShell 7 is involved.
- **Never fail a backup job.** The hook must exit `0` quickly, whatever happens.
- **Undocumented Veeam properties go in a profile, not in code.** A new VBR build should usually need only a new `.psd1`.
- **New target types** go in `src\Targets\` if they're general and testable, otherwise in a plugin. See [docs/writing-a-target.md](docs/writing-a-target.md). Add a renderer test to `tests\Run-Tests.ps1`.
- Add or update a test for any behaviour change, and keep the README in step.

## Releases

1. Set `$script:VAVersion` in `src\VeeamAware.psm1`.
2. Tag and push: `git tag v0.4.0 && git push origin v0.4.0`. A hyphenated tag (`v0.4.0-preview.1`) becomes a pre-release, which only the `preview` channel installs.
3. The release workflow runs the tests, checks that the tag matches `$script:VAVersion`, and publishes the GitHub release with generated notes.

Users get it from `Update-VeeamAware.ps1`, and the digest mentions it.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

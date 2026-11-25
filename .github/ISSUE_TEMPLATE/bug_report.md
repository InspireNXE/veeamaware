---
name: Bug report
about: Something VeeamAware did wrong, or a value in a report that's wrong or missing
labels: bug
---

**Remove webhook URLs, server names and anything else private before you post.** Logs can contain job, server and repository names.

### What happened

<!-- What you expected, and what happened instead. A screenshot of the card helps. -->

### Versions

- VBR version and edition (Help → About):
- Veeam module, from `(Get-Module Veeam.Backup.PowerShell -ListAvailable).Version`:
- VeeamAware (the footer of any message):
- Data source (`powershell`, `rest` or `auto`):
- Target (Discord, Teams, webhook, plugin):

### Logs

<!--
The relevant lines from C:\VeeamAware\logs\. Set "logging": { "level": "Debug" } in config\config.json and
reproduce if you can.
-->

```text

```

### For a wrong or missing value in a report

<!-- Attach the output of tools\Probe-VeeamPowerShell.ps1 (read-only; it writes tools\probe-output.txt). -->

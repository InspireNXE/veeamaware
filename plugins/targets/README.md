# Target plugins

Every `*.ps1` file in this folder is loaded when VeeamAware starts. Each one registers a target type with
`Register-VATargetType`. Use the type from `config\config.json` like any built-in one:

```json
{ "type": "textfile", "name": "audit-log", "path": "logs\\notifications.txt" }
```

Plugins run as the Veeam Backup Service account (Local System by default). Only add files you trust, and keep
this folder writable by administrators only. The installer sets that ACL for you.

- How to write one: [docs/writing-a-target.md](../../docs/writing-a-target.md)
- A complete example: [docs/examples/textfile-target.ps1](../../docs/examples/textfile-target.ps1)
- List the installed types and any load errors: `.\Test-VeeamAwareTarget.ps1 -ListTypes`

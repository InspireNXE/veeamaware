# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately through GitHub instead: open the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, how to reproduce it, and the VeeamAware and VBR versions. You should get a reply within a week. A fix ships as a new release, and the advisory credits you unless you'd rather it didn't.

## Supported versions

Only the newest release gets fixes. `C:\VeeamAware\Update-VeeamAware.ps1` installs it.

## What VeeamAware protects

VeeamAware runs as SYSTEM on the backup server and holds things worth protecting:

- **Webhook URLs** in `config\config.json`. Anyone who has one can post to that channel.
- **Target secrets and the REST credential** in `secrets\`, encrypted with DPAPI (machine scope).
- **Plugins** in `plugins\targets\`, which run as SYSTEM.

The installer limits `config\`, `secrets\`, `state\`, `logs\` and `plugins\` to SYSTEM and Administrators. A way around those limits, a way to make VeeamAware run code it shouldn't, or a leak of a secret into a log, message or payload all count as vulnerabilities.

Logs contain job, server and repository names. Remove them, and any webhook URLs, before you share logs anywhere.

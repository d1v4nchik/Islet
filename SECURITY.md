# Security Policy

## Supported Versions

Only the [latest release](../../releases/latest) is supported. Please update before reporting an issue (the one-line
installer in the README always installs the newest version).

## Reporting a Vulnerability

If you find a security vulnerability (for example: a way for another app or website to read Islet's Google sign-in or
Notion secret, a way to trick the sign-in redirect, or a crash caused by a crafted calendar event or task), please
**do not** open a public issue.

Instead, report it privately using [GitHub Security Advisories](../../security/advisories/new) for this repository.
Include:

- A description of the vulnerability and its impact
- Steps to reproduce
- Your macOS version and Islet version (right-click Islet, or see `Islet.app` › Get Info)

You should receive an initial response within a few days. Once a fix is available, we'll coordinate on disclosure timing
before any public writeup.

## Scope Notes

Islet only talks to Google (your calendar, read-only) and Notion (your tasks database). It doesn't collect analytics or
send data anywhere else.

It stores these in `~/Library/Application Support/Islet`, with permissions so only your macOS user can read them:

- `google_client.json`: your own Google Cloud OAuth client
- `google_token.json`: your Google sign-in (a refresh token with read-only calendar access)
- `notion.json`: your Notion integration secret and the tasks database ID
- `colors.json`: optional custom colors

Treat these files as sensitive. To revoke access, sign out from Islet's right-click menu and remove Islet under
[Google Account › Security › Third-party access](https://myaccount.google.com/connections), and delete the
integration in Notion.

During Google sign-in, Islet briefly listens on `127.0.0.1` (your Mac only) to receive the sign-in response, as Google
recommends for desktop apps, and stops as soon as it arrives.

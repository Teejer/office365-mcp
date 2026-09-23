# Office 365 MCP server (Planner, To Do, Outlook mail, calendar, shared mailbox)

Container for [`@jbctechsolutions/mcp-office365`](https://github.com/jbctechsolutions/mcp-office365),
a Microsoft Graph MCP server. Scoped to the presets you actually want — Teams
is intentionally excluded (that stays on the dedicated `teams` MCP).

> ## Attribution
>
> **All credit for the actual MCP server goes to [JBC Tech Solutions, LLC](https://github.com/jbctechsolutions/mcp-office365)**
> (Joel, `@jbctech`), who wrote and maintains
> [`@jbctechsolutions/mcp-office365`](https://www.npmjs.com/package/@jbctechsolutions/mcp-office365)
> (MIT licensed). This repository contains **no server code of its own** —
> only a Docker wrapper, an Entra app-registration walkthrough, and
> operational notes from running their package in a container.
> If you find this useful, go star [their repo](https://github.com/jbctechsolutions/mcp-office365).

## What's exposed

| Preset | Covers |
| --- | --- |
| `planner` | plans, buckets, tasks, category labels, task comments |
| `tasks` | Microsoft To Do — task lists, tasks, checklists, attachments |
| `mail` | read/search/send mail, drafts, replies, organize, rules, OOF |
| `calendar` | events, RSVP, rooms, sharing |
| `files` | OneDrive browse/read (also backs the shared-mailbox drive tools) |
| `meetings` | free/busy availability, "find a time everyone's free" |

~178 tools total. Destructive writes use a two-phase `prepare_*` → `confirm_*`
flow.

## Prerequisites: Entra app registration

1. entra.microsoft.com → App registrations → **New registration** — single-tenant.
2. **Authentication → Allow public client flows → Yes** (device-code login needs this).
3. **API permissions → Microsoft Graph → Delegated**, then **Grant admin consent**:

```
User.Read
User.ReadBasic.All
offline_access
Tasks.ReadWrite
Group.Read.All
Team.ReadBasic.All
Mail.ReadWrite
Mail.Send
Mail.Read.Shared
Calendars.ReadWrite
Calendars.Read.Shared
Contacts.ReadWrite
Files.Read.All
Files.ReadWrite
People.Read
Presence.Read.All
Sites.ReadWrite.All
Notes.ReadWrite
Channel.ReadBasic.All
ChannelMessage.Read.All
ChannelMessage.Send
Chat.ReadWrite
ChatMessage.Send
```

> **Why the Teams/OneNote/SharePoint scopes if Teams is excluded?** The upstream
> package signs in with **one fixed scope list regardless of preset** — if a
> requested permission is missing from the app registration, the device-code
> sign-in itself fails (AADSTS60001), even if you never touch those tools.
> Extra scopes you never use are harmless; missing ones are fatal.

## Configure

> **Note:** keep the `OUTLOOK_MCP_*` variable **names** exactly as they are —
> the app reads those names. Only the *values* are yours to fill in.

```bash
cp .env.example .env
# Fill in your Entra app's real client (application) ID and tenant (directory)
# ID — App registrations → your app. chmod 600 .env
```

## Use the published image (skip the build)

A ready-built image is on Docker Hub:

```bash
docker pull teejeer/office365-mcp        # or :1.0.0
```

Everything below works identically with `teejeer/office365-mcp` in place of
`office365-mcp`. The upstream package is **baked into the image at build
time** (pinned via the `O365_MCP_VERSION` build arg, current default `5.1.1`),
so published tags are reproducible and the container starts instantly with no
npm fetch. To upgrade upstream: bump the arg and release a new version:

```bash
docker build --build-arg O365_MCP_VERSION=5.2.0 -t office365-mcp .
```

Releases are cut with [`release.sh`](release.sh):

```bash
./release.sh 1.0.1 "what changed"   # rebuild, push :1.0.1 + :latest, git tag, GitHub release
```

## Authenticate (once)

Tokens are written by the app to `~/.mcp-office365` **inside the container**, so
that path must be mounted at a host directory the container can write to.

Make sure **no other office365-mcp container is running** first
(`docker ps | grep office365-mcp`) — the guard entrypoint will refuse to start
alongside one, on purpose (see [Token lifetime](#token-lifetime--why-one-container-at-a-time)).

```bash
mkdir -p ~/mcp-o365-state && chmod 777 ~/mcp-o365-state

docker build -t office365-mcp .

docker run --rm -it \
  --env-file .env \
  -v "$HOME/mcp-o365-state:/home/appuser/.mcp-office365" \
  --entrypoint /usr/local/bin/docker-entrypoint.sh \
  office365-mcp auth
```

Follow the printed URL (https://login.microsoft.com/device) + code. Tokens
persist in the mounted dir, so later runs refresh silently. Re-run with
`auth --status` to check, `auth --force` to re-consent after scope changes.

## Token lifetime — why one container at a time

The app already refreshes its access token silently whenever it expires; you
never need to babysit it. The fragile part is the **refresh token**: Microsoft
rotates it on every refresh (single-use), and the upstream MSAL cache plugin
(`~/.mcp-office365/tokens.json`) has **no cross-process locking** and writes the
file non-atomically. If two containers share one mounted state dir, the moment
a token refresh happens:

- the loser refreshes with the already-consumed refresh token → Entra rejects it
  (`invalid_grant` / `bad_token`) and can revoke the entire token family;
- msal-node then removes the "bad" refresh token from the cache and **persists
  that deletion over the file**, wiping the winner's fresh refresh token;
- every session now reports `AUTH_EXPIRED` until you redo the device-code login.

A container killed mid-write (e.g. the harness closes stdin at session end) can
also leave `tokens.json` truncated, which the plugin reads as "no cached
account".

The bundled `docker-entrypoint.sh` defends against both, from outside the
upstream code:

1. **flock single-instance guard** — a second container sharing the state dir
   exits immediately with an explanation instead of racing token refreshes.
   (This applies to containers started through the default entrypoint, i.e. the
   normal `docker run` forms in this README.)
2. **Self-heal** — if `tokens.json` is corrupt at startup but the rolling backup
   `tokens.json.bak` is valid, the backup is restored before the server starts.
3. **Rolling backup** — while running, `tokens.json` is copied to
   `tokens.json.bak` every 60 s (same uid as the writer, no host cron needed).

If the login does die anyway, just re-run the `auth` step above.

## Register with OpenCode

`~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "office365": {
      "type": "local",
      "command": [
        "docker", "run", "-i", "--rm",
        "--env-file", "/path/to/office365-mcp/.env",
        "-v", "/home/YOU/mcp-o365-state:/home/appuser/.mcp-office365",
        "office365-mcp"
      ],
      "timeout": 60000,
      "enabled": false
    }
  }
}
```

> **One session at a time.** Enabling this server in two OpenCode sessions (or
> any two concurrent `docker run`s of this image) shares one token cache and
> eventually destroys the login — see
> [Token lifetime](#token-lifetime--why-one-container-at-a-time). The guard
> entrypoint makes the second session fail fast with a clear message; the MCP
> will simply show as failed there. Keep it enabled in exactly one session, or
> give the second session its own state dir **and** its own `auth` login.

## Notes

- **Token path is hardcoded** to `~/.mcp-office365/tokens.json` in the app —
  `OUTLOOK_MCP_STATE_DIR` only moves the SQLite `state.db`, **not** the token
  cache. Mounting anywhere else silently loses your login.
- The container user is uid 1001; the host state dir must be writable by it
  (hence `chmod 777`, or chown to 1001 if you can).
- No credentials are baked into the image; they arrive via `--env-file`.
- An `AUTH_EXPIRED` / `session_expired` tool result means the saved login is
  gone (see [Token lifetime](#token-lifetime--why-one-container-at-a-time)) —
  re-run the `auth` step. Silent refresh itself needs no babysitting; do **not**
  add a keep-alive/refresh loop, it would only refresh-race the other sessions.
- If a write fails with `GRAPH_PERMISSION_DENIED`, your token predates a scope
  change — re-run the `auth` step.
- **License:** the wrapped upstream package is MIT (JBC Tech Solutions, LLC);
  see [LICENSE](LICENSE). The wrapper files in this repo are MIT as well.
- **Schema quirks** (observed in current build):
  - `list_emails` requires `folder_id` explicitly (e.g. `"inbox"`) — it has no default.
  - Batch deletes go `prepare_batch_delete_emails` → `confirm_batch_operation`,
    where `tokens` is an array of `{token_id, email_id}` objects (not plain strings).
    Validation errors are mislabeled `GRAPH_ERROR`.
  - `prepare_*` previews may render `timeReceived` with the wrong year (e.g. 2057) —
    cosmetic only, the underlying items are correct.
  - There is **no hard-delete/purge tool** — all deletes move items to Deleted
    Items. Permanently purge via Outlook on the web (Deleted Items → … →
    "Recover items deleted from this folder" → Purge) or let the 14-day
    retention age them out.

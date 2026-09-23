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

A fresh sign-in is fine while servers are running (it mints a new grant rather
than redeeming the shared refresh token), but on images **older than 1.3.0**
stop the other containers first — see [Token lifetime](#token-lifetime-and-multi-instance-use).

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

## Token lifetime and multi-instance use

The app refreshes its access token silently whenever it expires; you never need
to babysit it. The fragile part is the **refresh token**: Microsoft rotates it on
every refresh (single-use). Out of the box the upstream MSAL cache plugin
(`~/.mcp-office365/tokens.json`) has no cross-process locking and writes the
file non-atomically, so on the stock package two containers sharing one state
dir destroy the login the moment they refresh at the same time — the loser
redeems an already-consumed token (`invalid_grant` / `bad_token`, which can also
make Entra revoke the whole token family), and its failed refresh overwrites
the winner's new refresh token in the file. That is the "keeps losing
authorization" failure this image exists to prevent
([upstream issue #129](https://github.com/jbctechsolutions/mcp-office365/issues/129)).

**Since image 1.3.0 this build ships a patch that fixes the race, so ANY NUMBER
of containers may safely share ONE login/state dir.**
`patch/upstream-cache-patch.mjs` runs at image build time and:

1. wraps each silent-refresh window in a **cross-process lockfile**
   (`tokens.json.lock`, stolen if stale > 2 min, fail-open with a stderr warning
   after 45 s so a session never stalls forever). The winner refreshes; the
   waiter then finds the winner's fresh access token already on disk and returns
   it **without any second redeem call** — verified against a mock STS that
   enforces Entra's single-use rotation like the real service;
2. makes every cache write **atomic** (temp file + rename), so a container
   killed mid-write can no longer truncate the shared file;
3. logs a real stderr warning when `tokens.json` exists but won't parse,
   instead of silently pretending it is a first run.

The patch anchors on exact upstream source strings and **fails the build** if a
new package version moves them — when bumping `O365_MCP_VERSION`, re-verify the
patch against the new release before publishing.

`docker-entrypoint.sh` still adds belt-and-braces around it:

1. **Self-heal** — if `tokens.json` is corrupt at startup (e.g. a cache
   corrupted by a pre-1.3.0 image) but the rolling backup `tokens.json.bak` is
   valid, the backup is restored before the server starts.
2. **Rolling backup** — while running, `tokens.json` is copied to
   `tokens.json.bak` every 60 s (same uid as the writer, no host cron needed).
3. **Advisory** — prints a note when another container is detected on the same
   state dir (fine on 1.3.0+; a warning sign for older images).

If the login does die (e.g. it was poisoned by an older image before you
upgraded), just re-run the `auth` step above.

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

> **Multi-instance is supported since image 1.3.0.** You can enable this server
> in as many OpenCode sessions as you like — they share the one state dir and
> the one login, and the built-in refresh lock ([Token
> lifetime](#token-lifetime-and-multi-instance-use)) keeps their token refreshes
> from clobbering each other. On **older** images only one session at a time was
> safe; upgrade everything before enabling a second session.

## Notes

- **Token path is hardcoded** to `~/.mcp-office365/tokens.json` in the app —
  `OUTLOOK_MCP_STATE_DIR` only moves the SQLite `state.db`, **not** the token
  cache. Mounting anywhere else silently loses your login.
- The container user is uid 1001; the host state dir must be writable by it
  (hence `chmod 777`, or chown to 1001 if you can).
- No credentials are baked into the image; they arrive via `--env-file`.
- An `AUTH_EXPIRED` / `session_expired` tool result means the saved login is
  gone (see [Token lifetime](#token-lifetime-and-multi-instance-use)) — re-run
  the `auth` step. Silent refresh itself needs no babysitting; do **not** add a
  keep-alive/refresh loop — the app already refreshes on demand, and an extra
  refresher only adds refresh traffic.
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

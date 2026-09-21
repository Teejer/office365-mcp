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
offline_access
Tasks.ReadWrite
Group.Read.All
Team.ReadBasic.All
Mail.ReadWrite
Mail.Send
Calendars.ReadWrite
Mail.Read.Shared
Calendars.Read.Shared
Files.Read.All
```

## Configure

> **Note:** keep the `OUTLOOK_MCP_*` variable **names** exactly as they are —
> the app reads those names. Only the *values* are yours to fill in.

```bash
cp .env.example .env
# Fill in your Entra app's real client (application) ID and tenant (directory)
# ID — App registrations → your app. chmod 600 .env
```

## Authenticate (once)

Tokens are written by the app to `~/.mcp-office365` **inside the container**, so
that path must be mounted at a host directory the container can write to.

```bash
mkdir -p ~/mcp-o365-state && chmod 777 ~/mcp-o365-state

docker build -t office365-mcp .

docker run --rm -it \
  --env-file .env \
  -v "$HOME/mcp-o365-state:/home/appuser/.mcp-office365" \
  --entrypoint npx office365-mcp \
  -y @jbctechsolutions/mcp-office365 auth
```

Follow the printed URL (https://login.microsoft.com/device) + code. Tokens
persist in the mounted dir, so later runs refresh silently. Re-run with
`auth --status` to check, `auth --force` to re-consent after scope changes.

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

## Notes

- **Token path is hardcoded** to `~/.mcp-office365/tokens.json` in the app —
  `OUTLOOK_MCP_STATE_DIR` only moves the SQLite `state.db`, **not** the token
  cache. Mounting anywhere else silently loses your login.
- The container user is uid 1001; the host state dir must be writable by it
  (hence `chmod 777`, or chown to 1001 if you can).
- No credentials are baked into the image; they arrive via `--env-file`.
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

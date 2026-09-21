FROM node:24-slim

# npx needs a non-root home for the package cache + token/state store.
# Planner task *comments* use the Graph **beta** endpoint, so point MSAL/Graph
# at beta. (Task/plan/bucket CRUD works on v1; only Comments tab tools need
# beta — harmless either way.)
RUN useradd --create-home appuser
USER appuser
WORKDIR /home/appuser

ENV OUTLOOK_MCP_STATE_DIR=/home/appuser/.mcp-state \
    OUTLOOK_MCP_GRAPH_VERSION=beta
RUN mkdir -p /home/appuser/.mcp-state

# Credentials are NOT baked in — pass OUTLOOK_MCP_CLIENT_ID / TENANT_ID at
# runtime via --env-file. Mount a state dir at /home/appuser/.mcp-state so
# tokens survive container restarts (rebuilding/re-running without a mount
# loses them and forces a fresh device-code login).
# Presets chosen: planner (plans/buckets/tasks/comments), tasks (Microsoft To Do),
# mail + calendar (Outlook), files (OneDrive read for shared tools),
# meetings (free/busy + availability). Shared-mailbox tools ride along with the
# mail/calendar presets (there is no separate "shared" preset in this build).
# Teams is intentionally NOT included — that stays on the dedicated teams MCP.
ENTRYPOINT ["npx", "-y", "@jbctechsolutions/mcp-office365", "--preset", "planner,tasks,mail,calendar,files,meetings"]

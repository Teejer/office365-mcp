FROM node:24-slim

# The upstream MCP server is installed GLOBALLY at build time (not fetched via
# npx at container start), so the image is self-contained: it runs offline,
# starts instantly, and the baked-in package version is fixed by the build.
# Bump O365_MCP_VERSION and rebuild to upgrade the upstream package.
# Planner task *comments* use the Graph **beta** endpoint, so point MSAL/Graph
# at beta. (Task/plan/bucket CRUD works on v1; only Comments tab tools need
# beta — harmless either way.)
ARG O365_MCP_VERSION=5.1.1
RUN npm install -g @jbctechsolutions/mcp-office365@${O365_MCP_VERSION} \
    && npm cache clean --force

# Concurrency patch for the upstream token cache (upstream issue #129): a
# cross-process lock around the whole silent-refresh window + atomic cache
# writes, so MULTIPLE server instances can safely share ONE login. The patcher
# anchors on exact upstream strings and FAILS THE BUILD if they move — so when
# bumping O365_MCP_VERSION above, re-verify patch/upstream-cache-patch.mjs
# against the new package version before releasing.
COPY patch/upstream-cache-patch.mjs /tmp/upstream-cache-patch.mjs
RUN node /tmp/upstream-cache-patch.mjs \
    && rm /tmp/upstream-cache-patch.mjs

# Guard entrypoint: takes a single-instance flock on the state dir (the upstream
# token cache has no locking and Entra rotates refresh tokens, so two containers
# sharing one state dir will eventually kill the login) and self-heals a corrupt
# tokens.json from a rolling backup. See docker-entrypoint.sh for details.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

# Non-root home doubles as the token/state store location.
RUN useradd --create-home appuser
USER appuser
WORKDIR /home/appuser

ENV OUTLOOK_MCP_STATE_DIR=/home/appuser/.mcp-state \
    OUTLOOK_MCP_GRAPH_VERSION=beta
RUN mkdir -p /home/appuser/.mcp-state

# Credentials are NOT baked in — pass OUTLOOK_MCP_CLIENT_ID / TENANT_ID at
# runtime via --env-file. Mount a state dir at /home/appuser/.mcp-office365 so
# tokens survive container restarts (the app's token path is hardcoded there).
# Presets chosen: planner (plans/buckets/tasks/comments), tasks (Microsoft To Do),
# mail + calendar (Outlook), files (OneDrive read for shared tools),
# meetings (free/busy + availability). Shared-mailbox tools ride along with the
# mail/calendar presets (there is no separate "shared" preset in this build).
# Teams is intentionally NOT included — that stays on the dedicated teams MCP.
# The default preset lives in CMD so the guard entrypoint can also wrap the
# `auth` command:  --entrypoint /usr/local/bin/docker-entrypoint.sh <image> auth
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--preset", "planner,tasks,mail,calendar,files,meetings"]

# Draft upstream issue — @jbctechsolutions/mcp-office365

Target: https://github.com/jbctechsolutions/mcp-office365/issues
(Filed-against version: 5.1.1, bundled @azure/msal-node 5.5.0. Discovered while
running the server in Docker with `~/.mcp-office365` bind-mounted; same failure
applies to any two processes sharing one OS user's token cache.)

---

**Title:** Token cache plugin is not concurrency-safe — two server instances sharing `tokens.json` permanently kill the saved login

**Body:**

## Summary

`mcp-office365` is commonly run as a stdio MCP server that an agent harness
starts and kills per session (e.g. `docker run -i --rm ...`, or two OpenCode /
Claude Code sessions with the server enabled). When two server processes share
one `~/.mcp-office365/tokens.json`, the login reliably dies at the next token
refresh: every subsequent run reports `AUTH_EXPIRED` / `session_expired` and
requires a full device-code re-auth. Symptom in our environment: "keeps losing
authorization" every few sessions.

There is already a silent refresh on every Graph call (`getAccessToken` →
`acquireTokenSilent`), so this is not a "refresh never happens" bug — it is the
**persistence layer around refresh** that destroys the session.

## Three compounding flaws, all in `graph/auth/token-cache.js`

1. **No cross-process locking.** Microsoft refresh tokens for public clients
   are rotated (single-use). MSAL's cache plugin does read-file → (network
   refresh) → write-file with no lock and no re-read-before-write. Two
   processes that both loaded the cache before a refresh will both redeem the
   *same* refresh token. The loser gets `invalid_grant` (AADSTS700082), and
   Entra's reuse detection can revoke the whole token family — including the
   winner's new refresh token.

2. **The losing refresh persists a cache *without* any refresh token.** In
   msal-node's `RefreshTokenClient.acquireTokenWithCachedRefreshToken`, an
   `InteractionRequiredAuthError` with suberror `bad_token` triggers
   `cacheManager.removeRefreshToken(...)`, which sets `cacheHasChanged` and
   makes the plugin serialize the *loser's* in-memory cache (deserialized
   before the winner wrote) over `tokens.json` — clobbering the winner's fresh
   refresh token. A benign single-retry failure becomes total, permanent logout
   for every process sharing the file.

3. **Non-atomic writes + silent swallow on read.** `afterCacheAccess` uses
   `writeFileSync` (truncate, then write). Harnesses routinely SIGKILL the
   container when a session ends; a kill landing mid-write leaves
   `tokens.json` truncated/corrupt. `beforeCacheAccess` then catches the JSON
   parse error with an empty handler ("start fresh"), so the process boots as
   if it were a first-run user — indistinguishable from a genuinely missing
   login, and the good copy is unrecoverable.

## Reproduction (2 containers, one mounted cache)

```bash
mkdir -p state && chmod 777 state
docker run --rm -it -v $PWD/state:/home/appuser/.mcp-office365 --env-file .env \
  <image> auth                    # device-code sign-in, works

# two server instances on the same cache, long enough to span an AT expiry
docker run -d -i -v $PWD/state:/home/appuser/.mcp-office365 --env-file .env <image> &
docker run -d -i -v $PWD/state:/home/appuser/.mcp-office365 --env-file .env <image> &

# wait 60–90 min (or force expiry), then exercise either instance
```

Expected: both instances keep working (or the second transparently refuses to
refresh). Actual: both return `AUTH_EXPIRED` (`session_expired`); `tokens.json`
contains an `Account` entry but **no `RefreshToken` credential**.

## Suggested fixes

1. **Atomic writes:** write to `tokens.json.tmp.$$` in the same directory and
   `renameSync` it into place. Cheap, removes all corruption.
2. **Cross-process locking around the read → refresh → write window:** e.g.
   `proper-lockfile` (retry/wait) around `beforeCacheAccess`…STS call…
   `afterCacheAccess`, or at minimum re-read + merge disk state inside
   `afterCacheAccess` before serializing (`cache.deserialize(disk); cache.merge()`
   style) so a loser never overwrites a winner's refresh token.
3. **Don't let a failed silent refresh destroy the cache:** when
   `acquireTokenSilent` ends in `InteractionRequiredAuthError`, skip
   `afterCacheAccess` persistence (e.g. track that this cache load is for a
   read/refresh attempt and force `cacheHasChanged=false` on that failure
   path), or reload disk first and only delete the RT if disk still holds the
   same (now-known-bad) RT secret.
4. Smaller thing: `beforeCacheAccess`'s empty `catch {}` should at least log to
   stderr — "cache exists but failed to parse" currently masquerades as
   first-run.

## Workarounds already deployed downstream (for reference)

Our Docker wrapper added an external guard entrypoint: non-blocking `flock` on
the state dir so a second instance fails fast with an explanation, a startup
JSON-validation of `tokens.json` with restore from a `tokens.json.bak`, and a
60s rolling backup loop. These bound the damage but obviously can't fix the
race for anyone not running it through our image.

---

## Wrapper-side notes (this repo)

- Guard entrypoint: `docker-entrypoint.sh` (flock + self-heal + rolling backup),
  wired as `ENTRYPOINT` in the `Dockerfile`; default preset moved to `CMD` so
  `--entrypoint /usr/local/bin/docker-entrypoint.sh <image> auth` keeps the
  lock on the sign-in flow too.
- To file: `gh issue create --repo jbctechsolutions/mcp-office365 --title "..." --body-file <this file>`
  (paste only the body section).

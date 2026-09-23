#!/usr/bin/env node
/**
 * Build-time patch for @jbctechsolutions/mcp-office365's token cache
 * (upstream issue: https://github.com/jbctechsolutions/mcp-office365/issues/129).
 *
 * What it fixes:
 *   1. REFRESH RACE  — wraps msal's acquireTokenSilent()/getAccessToken() in a
 *      cross-process lockfile so only one process can be inside a token
 *      refresh at a time. Entra refresh tokens are single-use; msal-node 5.5
 *      always reloads tokens.json from disk at the start of acquireTokenSilent,
 *      so a blocked second process wakes up, finds the winner's fresh access
 *      token already on disk, and returns it WITHOUT a second redeem call.
 *      No double-redemption => no invalid_grant => no token-family revocation.
 *   2. CACHE CLOBBER — a lost refresh mutates the cache (removes the "bad"
 *      refresh token); with non-atomic whole-file writes that deletion used to
 *      overwrite the winner's fresh refresh token. Atomic tmp+rename writes
 *      plus the lock make the surviving cache always contain a live RT.
 *   3. CORRUPTION   — writeFileSync (truncate+write) killed mid-session left a
 *      half-written tokens.json that the loader silently treated as
 *      "first run". Writes are now atomic (rename), and a file that exists but
 *      fails to parse is logged to stderr instead of silently ignored.
 *
 * How: exact-string patching of the compiled dist. Every anchor must match
 * exactly once or the build FAILS — so bumping O365_MCP_VERSION in the
 * Dockerfile loudly flags any upstream reshuffle instead of silently
 * shipping an unpatched cache. Verified against upstream 5.1.1.
 *
 * Usage: node upstream-cache-patch.js <dir containing token-cache.js and
 *        device-code-flow.js>   (default: the baked image path)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const MARKER = 'OFFICE365-MCP CONCURRENCY PATCH';

const dir = process.argv[2]
    ?? '/usr/local/lib/node_modules/@jbctechsolutions/mcp-office365/dist/graph/auth';

// ---------------------------------------------------------------------------
// token-cache.js: atomic writes, logged parse failures, and the file lock.
// ---------------------------------------------------------------------------
const tokenCacheEdits = [
    {
        name: 'fs imports',
        find: `import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';`,
        replace: `import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, statSync, unlinkSync } from 'node:fs';`,
    },
    {
        name: 'beforeCacheAccess: log corrupt cache instead of silent "start fresh"',
        find: `        catch {
            // If we can't read the cache, start fresh
        }`,
        replace: `        catch (e) {
            // ${MARKER}: a corrupt cache no longer masquerades as first-run.
            if (!FileTokenCachePlugin.parseErrorLogged) {
                FileTokenCachePlugin.parseErrorLogged = true;
                console.error('office365-mcp: tokens.json exists but failed to parse (' +
                    (e instanceof Error ? e.message : String(e)) + '); starting with an empty cache. ' +
                    'This usually means an earlier process was killed mid-write; the container ' +
                    'entrypoint restores tokens.json.bak when one is available.');
            }
        }`,
    },
    {
        name: 'afterCacheAccess: atomic write (tmp + rename)',
        find: `                ensureCacheDir();
                const data = context.tokenCache.serialize();
                writeFileSync(TOKEN_CACHE_FILE, data, { mode: 0o600 });`,
        replace: `                ensureCacheDir();
                const data = context.tokenCache.serialize();
                // ${MARKER}: atomic publish so a kill mid-write can never
                // truncate the shared cache out from under another process.
                const tmp = TOKEN_CACHE_FILE + '.' + process.pid + '.tmp';
                try {
                    writeFileSync(tmp, data, { mode: 0o600 });
                    renameSync(tmp, TOKEN_CACHE_FILE);
                }
                catch (writeErr) {
                    try {
                        unlinkSync(tmp);
                    }
                    catch { /* tmp may not exist */ }
                    throw writeErr;
                }`,
    },
    {
        name: 'clearTokenCache: atomic write',
        find: `            writeFileSync(TOKEN_CACHE_FILE, '{}', { mode: 0o600 });`,
        replace: `            // ${MARKER}: atomic write (see afterCacheAccess)
            const tmp = TOKEN_CACHE_FILE + '.' + process.pid + '.tmp';
            writeFileSync(tmp, '{}', { mode: 0o600 });
            renameSync(tmp, TOKEN_CACHE_FILE);`,
    },
];

const LOCK_MODULE = `
// ---------------------------------------------------------------------------
// ${MARKER}
// Cross-process advisory lock around "decide to refresh -> redeem refresh
// token -> persist cache". Microsoft refresh tokens are single-use: two
// processes redeeming the same token is both a failed refresh and (via Entra
// reuse detection) a token-family revocation. The lock spans the whole
// acquireTokenSilent call; msal reloads tokens.json from disk inside it, so a
// waiter finds the winner's fresh access token and never redeems at all.
//
// Lockfile-free by design (mkdir is atomic on local and bind-mounted
// filesystems; no external deps). Timings tunable for tests:
//   OUTLOOK_MCP_CACHE_LOCK_WAIT_MS  (default 45000; then proceed UNLOCKED with
//                                    a stderr warning — degraded to upstream
//                                    behavior beats a stalled MCP session)
//   OUTLOOK_MCP_CACHE_LOCK_STALE_MS (default 120000; a lock dir older than
//                                    this is treated as leaked and broken)
// ---------------------------------------------------------------------------
const TOKEN_CACHE_LOCK_DIR = TOKEN_CACHE_FILE + '.lock';
const LOCK_WAIT_MS = Number(process.env['OUTLOOK_MCP_CACHE_LOCK_WAIT_MS'] ?? 45000);
const LOCK_STALE_MS = Number(process.env['OUTLOOK_MCP_CACHE_LOCK_STALE_MS'] ?? 120000);
/** Per-process FIFO so concurrent in-process callers queue fairly. */
let lockChain = Promise.resolve();
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
async function acquireLockDir() {
    const deadline = Date.now() + LOCK_WAIT_MS;
    for (;;) {
        try {
            mkdirSync(TOKEN_CACHE_LOCK_DIR);
            return true;
        }
        catch (e) {
            if (e.code !== 'EEXIST') {
                console.error('office365-mcp: token cache lock unavailable (' + e.code + '); proceeding unlocked');
                return false;
            }
            try {
                if (Date.now() - statSync(TOKEN_CACHE_LOCK_DIR).mtimeMs > LOCK_STALE_MS) {
                    console.error('office365-mcp: breaking stale token cache lock (held >' + LOCK_STALE_MS + 'ms)');
                    rmSync(TOKEN_CACHE_LOCK_DIR, { recursive: true, force: true });
                    continue;
                }
            }
            catch {
                continue; // lock vanished between checks; retry
            }
            if (Date.now() > deadline) {
                console.error('office365-mcp: WARNING another process has held the token cache lock for >' +
                    LOCK_WAIT_MS + 'ms; proceeding UNLOCKED for this call (refresh-race protection temporarily degraded)');
                return false;
            }
            await sleep(20 + Math.floor(Math.random() * 40));
        }
    }
}
function releaseLockDir() {
    try {
        rmSync(TOKEN_CACHE_LOCK_DIR, { recursive: true, force: true });
    }
    catch { /* already gone */ }
}
/**
 * Runs fn() with exclusive access to the token cache across processes.
 * Re-entrancy within this process is serialized through the FIFO chain, so
 * nested use (e.g. getAccessToken -> acquireTokenSilentDetailed) deadlocks
 * only if callers nest unlocked variants; patched call sites never do.
 */
export async function withTokenCacheLock(fn) {
    const run = async () => {
        const held = await acquireLockDir();
        try {
            return await fn();
        }
        finally {
            if (held) {
                releaseLockDir();
            }
        }
    };
    const result = lockChain.then(run, run);
    lockChain = result.then(() => undefined, () => undefined);
    return result;
}
`;

// ---------------------------------------------------------------------------
// device-code-flow.js: wrap the token-acquisition entry points in the lock.
// ---------------------------------------------------------------------------
const deviceCodeFlowEdits = [
    {
        name: 'import the lock helper',
        find: `import { createTokenCachePlugin, hasTokenCache } from './token-cache.js';`,
        replace: `import { createTokenCachePlugin, hasTokenCache, withTokenCacheLock } from './token-cache.js';`,
    },
    {
        name: 'rename getAccessToken to unlocked internal',
        find: `export async function getAccessToken(deviceCodeCallback = defaultDeviceCodeCallback, options = {}) {`,
        replace: `async function getAccessTokenUnlocked(deviceCodeCallback = defaultDeviceCodeCallback, options = {}) {`,
    },
    {
        name: 'getAccessToken calls the unlocked silent internal (no nested lock)',
        find: `    const silent = await acquireTokenSilentDetailed();`,
        replace: `    const silent = await acquireTokenSilentDetailedUnlocked();`,
    },
    {
        name: 'rename acquireTokenSilentDetailed to unlocked internal',
        find: `async function acquireTokenSilentDetailed() {`,
        replace: `async function acquireTokenSilentDetailedUnlocked() {`,
    },
];

const WRAPPED_EXPORTS = `
// ${MARKER}
// Public entry points serialized process-wide (see withTokenCacheLock in
// token-cache.js). getAccessTokenUnlocked uses the *_Unlocked internals
// directly, so there is no nested-lock deadlock; standalone callers of
// acquireTokenSilent still get the lock here. Interactive device-code sign-in
// is deliberately NOT lock-wrapped: it can legitimately take minutes while a
// human types the code, and holding the cache lock that long would stall
// every other session. It mints a NEW grant instead of redeeming the shared
// refresh token, so it does not participate in the rotation race.
export async function getAccessToken(...args) {
    return withTokenCacheLock(() => getAccessTokenUnlocked(...args));
}
async function acquireTokenSilentDetailed(...args) {
    return withTokenCacheLock(() => acquireTokenSilentDetailedUnlocked(...args));
}
`;

// ---------------------------------------------------------------------------

function applyFile(file, edits, appendix) {
    let src = readFileSync(file, 'utf-8');
    if (src.includes(MARKER)) {
        console.log(`patch: ${file} already patched — skipping`);
        return;
    }
    const missing = [];
    for (const { name, find, replace } of edits) {
        const count = src.split(find).length - 1;
        if (count !== 1) {
            missing.push(`${name} (found ${count} matches, expected 1)`);
            continue;
        }
        src = src.replace(find, replace);
    }
    if (missing.length > 0) {
        console.error(`PATCH FAILED for ${file} — upstream code has changed:\n  ` +
            missing.join('\n  ') +
            `\nRe-check this patch against the new @jbctechsolutions/mcp-office365 version before building.`);
        process.exit(1);
    }
    writeFileSync(file, src + appendix);
    console.log(`patch: ${file} OK (${edits.length} edits + lock module)`);
}

applyFile(join(dir, 'token-cache.js'), tokenCacheEdits, LOCK_MODULE);
applyFile(join(dir, 'device-code-flow.js'), deviceCodeFlowEdits, WRAPPED_EXPORTS);

// Import sanity: the patched modules must still load and export what the
// rest of the package imports from them.
const tc = await import(`file://${join(dir, 'token-cache.js')}`);
const dc = await import(`file://${join(dir, 'device-code-flow.js')}`);
for (const [name, mod, expected] of [
    ['token-cache.js', tc, ['FileTokenCachePlugin', 'createTokenCachePlugin', 'hasTokenCache', 'clearTokenCache', 'getTokenCacheDir', 'getTokenCacheFile', 'withTokenCacheLock']],
    ['device-code-flow.js', dc, ['acquireTokenInteractive', 'acquireTokenSilent', 'getAccessToken', 'isAuthenticated', 'getAccount', 'signOut', 'resetMsalInstance']],
]) {
    const gone = expected.filter((k) => mod[k] == null);
    if (gone.length > 0) {
        console.error(`PATCH VERIFY FAILED: ${name} lost exports: ${gone.join(', ')}`);
        process.exit(1);
    }
}
console.log('patch: export verification passed');

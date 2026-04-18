#!/usr/bin/env node
/**
 * install-robust.mjs
 *
 * Robust global install wrapper for @dayour/windows-clippy-mcp. Handles the
 * common Windows EBUSY failure mode where the widget (WidgetHost.exe) or a
 * spawned node child is still holding files in the global node_modules
 * directory.
 *
 * Behavior:
 *   1. Stop any running WidgetHost.exe + child node.exe under the global
 *      package path.
 *   2. Run `npm install -g --force <target>` with exponential backoff on
 *      EBUSY / EPERM / EACCES. Max 5 attempts, base 1s, cap 30s.
 *   3. Verify critical install paths exist (mcp-apps server, bin shims).
 *
 * Usage:
 *   node scripts/install-robust.mjs                         # installs from cwd tarball pattern dayour-windows-clippy-mcp-*.tgz
 *   node scripts/install-robust.mjs <path-to-tarball-or-dir>
 *   node scripts/install-robust.mjs --latest                # npm install -g @dayour/windows-clippy-mcp@latest
 *
 * Exit codes:
 *   0  success
 *   1  install failed after all retries
 *   2  post-install verification failed
 *   3  invalid arguments
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const MAX_ATTEMPTS = 5;
const BASE_DELAY_MS = 1000;
const MAX_DELAY_MS = 30_000;
const PKG_NAME = "@dayour/windows-clippy-mcp";

function log(msg) {
    // eslint-disable-next-line no-console
    console.log(`[install-robust] ${msg}`);
}

function warn(msg) {
    // eslint-disable-next-line no-console
    console.warn(`[install-robust] WARNING: ${msg}`);
}

function err(msg) {
    // eslint-disable-next-line no-console
    console.error(`[install-robust] ERROR: ${msg}`);
}

function findGlobalRoot() {
    const res = spawnSync("npm", ["root", "-g"], { encoding: "utf8", shell: true });
    if (res.status === 0) {
        return res.stdout.trim();
    }
    const fallback = process.platform === "win32"
        ? join(process.env.APPDATA || "", "npm", "node_modules")
        : "/usr/local/lib/node_modules";
    warn(`npm root -g failed, falling back to ${fallback}`);
    return fallback;
}

function stopRunningWidget(globalRoot) {
    if (process.platform !== "win32") return;
    const pkgDir = join(globalRoot, "@dayour", "windows-clippy-mcp");

    const res = spawnSync(
        "powershell",
        [
            "-NoProfile",
            "-Command",
            `Get-Process -ErrorAction SilentlyContinue WidgetHost | Select-Object -Property Id | ConvertTo-Json -Compress`,
        ],
        { encoding: "utf8" },
    );
    if (res.status !== 0) return;
    const out = (res.stdout || "").trim();
    if (!out) return;

    let entries = [];
    try {
        const parsed = JSON.parse(out);
        entries = Array.isArray(parsed) ? parsed : [parsed];
    } catch {
        return;
    }

    for (const entry of entries) {
        const pid = entry?.Id;
        if (!pid) continue;
        log(`Stopping WidgetHost PID ${pid}`);
        spawnSync("powershell", ["-NoProfile", "-Command", `Stop-Process -Id ${pid} -Force -ErrorAction SilentlyContinue`]);
    }

    const nodeRes = spawnSync(
        "powershell",
        [
            "-NoProfile",
            "-Command",
            `Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*${pkgDir.replaceAll("\\", "\\\\")}*' } | Select-Object -Property ProcessId | ConvertTo-Json -Compress`,
        ],
        { encoding: "utf8" },
    );
    if (nodeRes.status === 0 && nodeRes.stdout.trim()) {
        try {
            const parsed = JSON.parse(nodeRes.stdout.trim());
            const arr = Array.isArray(parsed) ? parsed : [parsed];
            for (const entry of arr) {
                const pid = entry?.ProcessId;
                if (!pid) continue;
                log(`Stopping node child PID ${pid} (holding ${pkgDir})`);
                spawnSync("powershell", ["-NoProfile", "-Command", `Stop-Process -Id ${pid} -Force -ErrorAction SilentlyContinue`]);
            }
        } catch {
            // ignore
        }
    }
}

function resolveTarget(argv) {
    if (argv.includes("--latest")) {
        return { kind: "registry", spec: `${PKG_NAME}@latest` };
    }
    const explicit = argv.find((a) => !a.startsWith("--"));
    if (explicit) {
        const abs = resolve(explicit);
        if (!existsSync(abs)) {
            err(`target does not exist: ${abs}`);
            process.exit(3);
        }
        return { kind: "file", spec: abs };
    }

    const tarballs = readdirSync(process.cwd())
        .filter((name) => /^dayour-windows-clippy-mcp-.*\.tgz$/.test(name))
        .map((name) => ({ name, mtime: statSync(join(process.cwd(), name)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime);
    if (tarballs.length === 0) {
        err(`no tarball found in ${process.cwd()} matching dayour-windows-clippy-mcp-*.tgz`);
        err("pass a tarball path explicitly or use --latest to install from the npm registry");
        process.exit(3);
    }
    const picked = join(process.cwd(), tarballs[0].name);
    log(`auto-picked tarball: ${picked}`);
    return { kind: "file", spec: picked };
}

function runNpmInstall(spec) {
    return new Promise((resolvePromise) => {
        const args = ["install", "-g", "--force", spec];
        log(`npm ${args.join(" ")}`);
        const child = spawn("npm", args, { stdio: ["ignore", "pipe", "pipe"], shell: true });

        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (d) => {
            stdout += d.toString();
        });
        child.stderr.on("data", (d) => {
            stderr += d.toString();
        });
        child.on("close", (code) => {
            resolvePromise({ code, stdout, stderr });
        });
    });
}

function isTransientError(stderr) {
    if (!stderr) return false;
    return /EBUSY|EPERM|EACCES|ENOTEMPTY|file is locked|used by another process/i.test(stderr);
}

function computeBackoff(attempt) {
    const exp = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** (attempt - 1));
    const jitter = Math.floor(Math.random() * 500);
    return exp + jitter;
}

function verifyInstall(globalRoot) {
    const pkgDir = join(globalRoot, "@dayour", "windows-clippy-mcp");
    const required = [
        join(pkgDir, "package.json"),
        join(pkgDir, "src", "mcp-apps", "server.mjs"),
        join(pkgDir, "scripts", "start-widget.js"),
    ];
    // Global bin shims declared in package.json "bin" field. On Windows
    // npm materializes .cmd wrappers next to the global prefix (one
    // directory up from node_modules).
    const binRoot = join(globalRoot, "..");
    const shimCandidates = [
        "clippy",
        "clippy-widget",
        "clippy-live-tile",
        "clippy_widget_refresh",
        "clippy_widget_restart",
    ];
    const missing = required.filter((p) => !existsSync(p));
    if (missing.length > 0) {
        err(`post-install verification failed. Missing:\n  - ${missing.join("\n  - ")}`);
        return false;
    }
    const foundShims = shimCandidates.filter((name) =>
        existsSync(join(binRoot, `${name}.cmd`)) || existsSync(join(binRoot, name))
    );
    if (foundShims.length === 0) {
        log(`warning: no global bin shim found under ${binRoot}; package content is complete but CLI wrappers may be missing`);
    } else {
        log(`verified: ${foundShims.length}/${shimCandidates.length} bin shims present (${foundShims.join(", ")})`);
    }
    log(`verified: ${pkgDir} is complete`);
    return true;
}

async function main() {
    const argv = process.argv.slice(2);
    const target = resolveTarget(argv);
    const globalRoot = findGlobalRoot();
    log(`global root: ${globalRoot}`);

    stopRunningWidget(globalRoot);

    let lastError = "";
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
        const { code, stdout, stderr } = await runNpmInstall(target.spec);
        if (code === 0) {
            if (stdout.trim()) log(stdout.trim().split("\n").slice(-3).join(" | "));
            if (!verifyInstall(globalRoot)) process.exit(2);
            log(`install succeeded on attempt ${attempt}`);
            process.exit(0);
        }

        lastError = stderr || stdout || `exit code ${code}`;

        if (!isTransientError(stderr)) {
            err(`non-transient failure on attempt ${attempt}:`);
            err(lastError.trim().split("\n").slice(-5).join("\n"));
            process.exit(1);
        }

        if (attempt === MAX_ATTEMPTS) {
            err(`transient failure persisted after ${MAX_ATTEMPTS} attempts`);
            break;
        }

        const delay = computeBackoff(attempt);
        warn(`transient install failure (EBUSY/EPERM/EACCES); retry ${attempt}/${MAX_ATTEMPTS - 1} after ${delay}ms`);
        stopRunningWidget(globalRoot);
        await sleep(delay);
    }

    err("install failed after all retries. Last error:");
    err(lastError.trim().split("\n").slice(-10).join("\n"));
    process.exit(1);
}

main().catch((e) => {
    err(`unexpected: ${e?.stack || e}`);
    process.exit(1);
});

#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const IS_MACOS = process.platform === "darwin";
const BINARY = IS_MACOS ? "./dist/bin/capsper" : "./dist/bin/capsper-cuda";
const SCRIPT_DIR = import.meta.dir;
const TARBALL = IS_MACOS ? "capsper-macos-arm64.tar.gz" : "capsper-linux-x86_64.tar.gz";
const LIB_DIR = IS_MACOS ? "dist/lib-macos" : "dist/lib";

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps() {
    if (IS_MACOS) {
        await ensureDepsMacOS();
    } else {
        await ensureDepsLinux();
    }
}

async function ensureDepsMacOS() {
    if (!await which("brew")) {
        console.error("ERROR: Homebrew is required on macOS. Install from https://brew.sh");
        process.exit(1);
    }

    const missing: string[] = [];
    if (!await which("shellcheck")) missing.push("shellcheck");

    if (missing.length > 0) {
        console.log(`Installing missing brew packages: ${missing.join(", ")}`);
        await $`brew install ${missing}`;
    }
}

async function ensureDepsLinux() {
    const missing: string[] = [];

    // Core build deps
    if (!await which("pkg-config")) missing.push("pkg-config");

    // PipeWire dev headers
    const { exitCode: pwCheck } = await $`pkg-config --exists libpipewire-0.3`.quiet().nothrow();
    if (pwCheck !== 0) missing.push("libpipewire-0.3-dev");

    // Streaming test deps
    if (!await which("pv")) missing.push("pv");
    if (!await which("nc") && !await which("ncat")) missing.push("ncat");

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

function ensureBinary() {
    if (IS_MACOS) {
        if (!existsSync("./dist/bin/capsper")) {
            console.error("Binary not found: ./dist/bin/capsper");
            console.error("Run: ./run.ts build");
            process.exit(1);
        }
    } else {
        if (!existsSync("./dist/bin/capsper-cuda") && !existsSync("./dist/bin/capsper-cpu")) {
            console.error("No binaries found in dist/bin/");
            console.error("Run: ./run.ts build");
            process.exit(1);
        }
    }
}

// ─── Version ────────────────────────────────────────────────────────────────

async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, '').split('.')[0];
    const revisions = (await $`git rev-list --count ${branch}`.quiet()).text().trim();
    return `0.${revisions}.${buildNumber}`;
}

// ─── Commands ──────────────────────────────────────────────────────────────

export async function build() {
    await ensureDeps();
    const ver = await version();
    if (IS_MACOS) {
        console.log(`Building v${ver} (coreml)...`);
        await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
    } else {
        console.log(`Building v${ver} (ort-cuda)...`);
        await $`zig build --prefix dist -Dbackend=ort_cuda -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
        console.log(`Building v${ver} (ort-cpu)...`);
        await $`zig build --prefix dist -Dbackend=ort_cpu -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
        // Symlink capsper → capsper-cuda for dev (dist creates a proper launcher script)
        await $`ln -sf capsper-cuda dist/bin/capsper`;
    }
}

export async function clean() {
    await $`rm -rf dist/bin .zig-cache`;
    console.log("Cleaned.");
}

export async function setup() {
    await build();

    // Delegate permissions, audio detection, and service setup to install script
    const installScript = IS_MACOS ? "install-macos.sh" : "install.sh";
    const installSh = join(SCRIPT_DIR, "dist", installScript);
    if (existsSync(installSh)) {
        await $`bash ${installSh}`;
    } else {
        console.error(`Install script not found: ${installSh}`);
    }
}

/** Default target: build → lint → unit tests → short regressions + plumbing. */
export async function dev() {
    await build();
    console.log("Running lint...");
    await $`shellcheck dist/*.sh bootstrap.sh`;
    console.log("Running unit + property tests...");
    await $`zig build test`;
    console.log("Running integration smoke tests...");
    if (IS_MACOS) {
        await $`bun test test/regression.test.ts test/ca-stream.test.ts`;
    } else {
        await $`bun test test/regression.test.ts test/pw-stream.test.ts`;
    }
}

export async function test() {
    await $`zig build test`;
}

export async function shortTest() {
    ensureBinary();
    await $`bun test test/regression.test.ts`;
}

export async function mediumTest() {
    ensureBinary();
    process.env.TEST_GROUP = "medium";
    await $`bun test test/regression.test.ts`;
}

export async function longTest() {
    ensureBinary();
    process.env.TEST_GROUP = "long";
    await $`bun test test/regression.test.ts`;
}

export async function slowTest() {
    ensureBinary();
    process.env.SLOW_TESTS = "1";
    await $`bun test test/`;
}

export async function dist() {
    ensureBinary();

    if (IS_MACOS) {
        await distMacOS();
    } else {
        await distLinux();
    }
}

async function distLinux() {
    // Validate that ORT libs are real ELF binaries
    const { stdout } = await $`file dist/lib/*.so`.quiet();
    const lines = stdout.toString().trim().split("\n");
    const bad = lines.filter(l => !l.includes("ELF") && !l.includes("symbolic link"));
    if (bad.length > 0) {
        console.error("ERROR: dist/lib/ contains non-ELF files:");
        bad.forEach(l => console.error(`  ${l}`));
        process.exit(1);
    }

    // Validate no AVX-512 in both binaries
    for (const bin of ["dist/bin/capsper-cuda", "dist/bin/capsper-cpu"]) {
        if (!existsSync(bin)) continue;
        const { stdout: objdumpOut } = await $`objdump -d ${bin} | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
        const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
        if (avx512Count > 0) {
            console.error(`ERROR: ${bin} contains ${avx512Count} AVX-512 instructions`);
            process.exit(1);
        }
    }

    // Create launcher script
    const launcher = `#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    exec "$DIR/capsper-cuda" "$@"
else
    exec "$DIR/capsper-cpu" "$@"
fi
`;
    await Bun.write("dist/bin/capsper", launcher);
    await $`chmod +x dist/bin/capsper`;

    const ver = await version();
    await Bun.write("dist/VERSION", ver);
    await $`tar -czf ${TARBALL} -C dist bin/ lib/ install.sh install-common.sh capsper-update.sh capsper-apply-update.sh capsper-rollback.sh VERSION`;
    await $`sha256sum ${TARBALL} > ${TARBALL}.sha256`;
    console.log(`Tarball: ${TARBALL} (v${ver})`);
}

async function distMacOS() {
    const ver = await version();
    await Bun.write("dist/VERSION", ver);

    await $`rm -rf /tmp/capsper-dist-macos`;
    await $`mkdir -p /tmp/capsper-dist-macos`;
    await $`cp -r dist/bin /tmp/capsper-dist-macos/`;
    // Rename install-macos.sh → install.sh so same instructions work on both platforms
    await $`cp dist/install-macos.sh /tmp/capsper-dist-macos/install.sh`;
    await $`cp dist/install-common.sh /tmp/capsper-dist-macos/`;
    await $`cp dist/capsper-update.sh /tmp/capsper-dist-macos/`;
    await $`cp dist/capsper-apply-update.sh /tmp/capsper-dist-macos/`;
    await $`cp dist/capsper-rollback.sh /tmp/capsper-dist-macos/`;
    await $`cp dist/VERSION /tmp/capsper-dist-macos/`;
    await $`tar -czf ${TARBALL} -C /tmp/capsper-dist-macos .`;
    await $`shasum -a 256 ${TARBALL} > ${TARBALL}.sha256`;
    await $`rm -rf /tmp/capsper-dist-macos`;
    console.log(`Tarball: ${TARBALL} (v${ver})`);
}

export async function lint() {
    await $`shellcheck dist/*.sh bootstrap.sh`;
}

export async function ci() {
    await ensureDeps();
    const ver = await version();
    console.log("Running lint...");
    await $`shellcheck dist/*.sh bootstrap.sh`;
    console.log("Running tests...");
    await $`zig build test`;
    await build();
    await dist();
    if (process.env.GH_TOKEN) {
        const noCreateRelease = process.env.NO_CREATE_RELEASE === "true";
        if (noCreateRelease) {
            console.log(`Uploading assets to release v${ver}...`);
            for (let attempt = 1; attempt <= 10; attempt++) {
                const { exitCode } = await $`gh release upload v${ver} ${TARBALL} ${TARBALL}.sha256 --clobber`.nothrow();
                if (exitCode === 0) break;
                if (attempt === 10) {
                    console.error(`Failed to upload after ${attempt} attempts`);
                    process.exit(1);
                }
                console.log(`Release not ready yet (attempt ${attempt}/10), waiting 30s...`);
                await Bun.sleep(30_000);
            }
        } else {
            const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
            console.log(`Creating release v${ver}...`);
            await $`gh release create v${ver} ${TARBALL} ${TARBALL}.sha256 --title v${ver} --notes ${commitMsg}`;
        }
    }
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, ci, version: printVersion,
    "short-test": shortTest,
    "medium-test": mediumTest,
    "long-test": longTest,
    "slow-test": slowTest,
};

const command = process.argv[2] || "dev";
const args = process.argv.slice(3);

const fn = commands[command];
if (fn) {
    try {
        await fn(...args);
    } catch (e: any) {
        console.error(`Command failed: ${command}`, ...args);
        console.error(e.message || e);
        process.exit(1);
    }
} else {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}

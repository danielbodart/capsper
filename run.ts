#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const BINARY = "./dist/bin/capsper";
const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps(opts?: { cuda?: boolean }) {
    const missing: string[] = [];

    // Core build deps
    if (!await which("pkg-config")) missing.push("pkg-config");

    // PipeWire dev headers
    const { exitCode: pwCheck } = await $`pkg-config --exists libpipewire-0.3`.quiet().nothrow();
    if (pwCheck !== 0) missing.push("libpipewire-0.3-dev");

    // Git LFS (needed to pull real shared libs from LFS)
    if (!await which("git-lfs")) missing.push("git-lfs");

    // Streaming test deps
    if (!await which("pv")) missing.push("pv");
    if (!await which("nc") && !await which("ncat")) missing.push("ncat");

    // CUDA deps (only for rebuild-whisper)
    if (opts?.cuda) {
        if (!await which("cmake")) missing.push("cmake");
        if (!await which("nvcc")) {
            console.error("ERROR: nvcc not found. CUDA toolkit required for rebuild-whisper.");
            process.exit(1);
        }
        if (!await which("nvidia-smi")) {
            console.error("ERROR: nvidia-smi not found. CUDA driver required for rebuild-whisper.");
            process.exit(1);
        }
    }

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

async function ensureSubmodule() {
    // Check if whisper.cpp is populated
    if (!existsSync("whisper.cpp/CMakeLists.txt")) {
        console.log("Initializing whisper.cpp submodule...");
        await $`git submodule update --init --recursive`;
    }
}

async function ensureLfs() {
    // Check if any versioned .so files are LFS pointers instead of real binaries
    const { stdout } = await $`head -c 20 dist/lib/*.so.*.*.* 2>/dev/null || true`.quiet();
    if (stdout.toString().includes("version https://git-lfs")) {
        console.log("LFS pointer files detected in dist/lib/ — pulling real binaries...");
        await $`git lfs install`;
        await $`git lfs pull`;
    }
}

async function confirm(message: string): Promise<boolean> {
    process.stdout.write(`${message} [Y/n] `);
    return new Promise<boolean>(resolve => {
        const onData = (chunk: Buffer) => {
            process.stdin.removeListener("data", onData);
            process.stdin.pause();
            const answer = chunk.toString().trim().toLowerCase();
            resolve(answer === "" || answer === "y" || answer === "yes");
        };
        process.stdin.resume();
        process.stdin.on("data", onData);
    });
}

async function ensureModels() {
    const missing: string[] = [];
    if (!existsSync(MODEL)) missing.push(`Whisper model (large-v3-turbo-q5_0, ~574 MB)`);
    if (!existsSync(VAD_MODEL)) missing.push(`VAD model (silero-v5.1.2, ~2 MB)`);

    if (missing.length === 0) return;

    console.log(`Missing models:\n${missing.map(m => `  - ${m}`).join("\n")}`);
    if (!await confirm("Download now?")) {
        console.error("Models required. Download manually:");
        console.error("  cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0");
        console.error("  cd whisper.cpp/models && ./download-vad-model.sh silero-v5.1.2");
        process.exit(1);
    }

    if (!existsSync(MODEL)) {
        console.log("Downloading Whisper model...");
        await $`cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0`;
    }
    if (!existsSync(VAD_MODEL)) {
        console.log("Downloading VAD model...");
        await $`cd whisper.cpp/models && ./download-vad-model.sh silero-v5.1.2`;
    }
}

function ensureBinary() {
    if (!existsSync(BINARY)) {
        console.error(`Binary not found: ${BINARY}`);
        console.error("Run: ./run.ts build");
        process.exit(1);
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
    await ensureSubmodule();
    await ensureLfs();
    if (!process.env.CI) await ensureModels();
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
}

export async function rebuildWhisper(...args: string[]) {
    if (args.includes("--clean")) {
        await $`rm -rf .zig-cache/cmake`;
    }
    await ensureDeps({ cuda: true });
    await ensureSubmodule();
    console.log("Building whisper.cpp shared libs...");
    await $`zig build rebuild-libs --prefix dist`;
    console.log("Done. Commit dist/lib/ to check in the updated libraries.");
}

export async function clean() {
    await $`rm -rf dist/bin .zig-cache`;
    console.log("Cleaned.");
}

export async function setup() {
    await build();

    // Delegate permissions, audio detection, and service setup to install.sh
    // (auto-detects dev mode via ../.git)
    const installSh = join(SCRIPT_DIR, "dist", "install.sh");
    await $`bash ${installSh}`;
}

/** Default target: build → unit tests → quick integration tests (stream + pw-stream). */
export async function dev() {
    await build();
    console.log("Running unit + property tests...");
    await $`zig build test`;
    console.log("Running integration smoke tests...");
    await $`bun test test/stream.test.ts test/pw-stream.test.ts`;
}

export async function test() {
    await $`zig build test`;
}

export async function slowTest(testName?: string, ...extra: string[]) {
    ensureBinary();
    if (extra.length > 0) {
        if (testName === "stream" || testName === "pw-stream") {
            process.env.TEST_WAV = extra[0];
        } else if (testName === "compare") {
            process.env.TEST_NAME = extra[0];
        }
    }
    if (testName) {
        await $`bun test test/${testName}.test.ts`;
    } else {
        await $`bun test test/`;
    }
}

export async function dist() {
    ensureBinary();

    // Validate that versioned shared libs are real ELF binaries, not LFS pointers
    // (skip bare .so symlinks — only check the actual .so.X.Y.Z files)
    const { stdout } = await $`file dist/lib/*.so.*.*.*`.quiet();
    const lines = stdout.toString().trim().split("\n");
    const bad = lines.filter(l => !l.includes("ELF"));
    if (bad.length > 0) {
        console.error("ERROR: dist/lib/ contains non-ELF files (likely LFS pointers):");
        bad.forEach(l => console.error(`  ${l}`));
        console.error("Run: git lfs pull");
        process.exit(1);
    }

    const ver = await version();
    const tarball = `capsper-linux-x86_64-${ver}.tar.gz`;
    await $`tar -czf ${tarball} -C dist bin/ lib/ install.sh`;
    console.log(`Tarball: ${tarball}`);
}

export async function ci() {
    await ensureSubmodule();
    await ensureLfs();
    const ver = await version();
    console.log("Running tests...");
    await $`zig build test`;
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
    await dist();
    if (process.env.GH_TOKEN) {
        const tarball = `capsper-linux-x86_64-${ver}.tar.gz`;
        const commitMsg = (await $`git log -1 --format=%s`.quiet()).text().trim();
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} ${tarball} --title v${ver} --notes ${commitMsg}`;
    }
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, clean, setup, test, dist, ci, version: printVersion,
    "slow-test": slowTest,
    "rebuild-whisper": rebuildWhisper,
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

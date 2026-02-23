#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const BINARY = "./dist/bin/capsper";
const MODEL = "dist/models/ggml-large-v3-turbo-q5_0.bin";
const SCRIPT_DIR = import.meta.dir;
const TARBALL = "capsper-linux-x86_64.tar.gz";

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
            console.error("       Install with: sudo apt install nvidia-cuda-toolkit");
            process.exit(1);
        }
        // Verify CUDA 12.x toolkit (not 13+ which requires bleeding-edge drivers)
        const nvccOut = await $`nvcc --version`.text();
        const cudaVer = nvccOut.match(/release (\d+)\./)?.[1];
        if (cudaVer !== "12") {
            console.error(`ERROR: CUDA 12 toolkit required (found CUDA ${cudaVer ?? "unknown"}).`);
            console.error("       Install with: sudo apt install nvidia-cuda-toolkit");
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
    // Check if submodules are populated
    if (!existsSync("whisper.cpp/CMakeLists.txt")) {
        console.log("Initializing submodules...");
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
    if (existsSync(MODEL)) return;

    console.log("Missing model: Whisper large-v3-turbo-q5_0 (~574 MB)");
    if (!await confirm("Download now?")) {
        console.error("Model required. Download manually:");
        console.error("  curl -L -o dist/models/ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin");
        process.exit(1);
    }

    console.log("Downloading Whisper model...");
    await $`curl -L --progress-bar -o ${MODEL} https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin`;
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
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
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

/** Default target: build → lint → unit tests → short regressions + pw plumbing. */
export async function dev() {
    await build();
    console.log("Running static analysis...");
    await $`zig build analyze`;
    await $`shellcheck dist/*.sh bootstrap.sh`;
    console.log("Running unit + property tests...");
    await $`zig build test`;
    console.log("Running integration smoke tests...");
    await $`bun test test/regression.test.ts test/pw-stream.test.ts`;
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

export async function vadTest(...args: string[]) {
    await build();
    const input = args[0] || "test/long-pause.wav";
    await $`./dist/bin/vad-filter-test ${input} ${args.slice(1)}`;
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

    // Validate no shared lib has a hardcoded absolute RUNPATH (must be $ORIGIN or empty)
    const { stdout: rpathOut } = await $`readelf -d dist/lib/*.so.*.*.* 2>/dev/null`.quiet();
    const rpathLines = rpathOut.toString().split("\n").filter(l => l.includes("RUNPATH") || l.includes("RPATH"));
    const absolutePaths = rpathLines.filter(l => l.includes("Library") && !l.includes("$ORIGIN") && /\/[a-zA-Z]/.test(l));
    if (absolutePaths.length > 0) {
        console.error("ERROR: shared libs have hardcoded absolute RUNPATH (won't work when installed):");
        absolutePaths.forEach(l => console.error(`  ${l.trim()}`));
        console.error("Rebuild with: ./run.ts rebuild-whisper");
        process.exit(1);
    }

    // Validate no AVX-512 instructions in the binary (must be portable to x86_64_v3)
    const { stdout: objdumpOut } = await $`objdump -d dist/bin/capsper | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
    const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
    if (avx512Count > 0) {
        console.error(`ERROR: binary contains ${avx512Count} AVX-512 instructions (not portable)`);
        console.error("Rebuild with: -Dcpu=x86_64_v3");
        process.exit(1);
    }

    const ver = await version();
    await Bun.write("dist/VERSION", ver);
    await $`tar -czf ${TARBALL} -C dist --exclude='models/ggml-large-v3-turbo-q5_0.bin' bin/ lib/ models/ install.sh capsper-update.sh capsper-apply-update.sh capsper-rollback.sh VERSION`;
    await $`sha256sum ${TARBALL} > ${TARBALL}.sha256`;
    console.log(`Tarball: ${TARBALL} (v${ver})`);
}

export async function lint() {
    await $`zig build analyze`;
    await $`shellcheck dist/*.sh bootstrap.sh`;
}

export async function ci() {
    await ensureSubmodule();
    await ensureLfs();
    const ver = await version();
    console.log("Running static analysis...");
    await $`zig build analyze`;
    await $`shellcheck dist/*.sh bootstrap.sh`;
    console.log("Running tests...");
    await $`zig build test`;
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
    await dist();
    if (process.env.GH_TOKEN) {
        const commitMsg = (await $`git log -1 --format=%s`.quiet()).text().trim();
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} ${TARBALL} ${TARBALL}.sha256 --title v${ver} --notes ${commitMsg}`;
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
    "vad-test": vadTest,
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

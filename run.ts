#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const BINARY = "./zig-out/bin/zigsper";
const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps() {
    const missing: string[] = [];

    // Core build deps
    if (!await which("cmake")) missing.push("cmake");
    if (!await which("pkg-config")) missing.push("pkg-config");

    // PipeWire dev headers
    const { exitCode: pwCheck } = await $`pkg-config --exists libpipewire-0.3`.quiet().nothrow();
    if (pwCheck !== 0) missing.push("libpipewire-0.3-dev");

    // CUDA
    if (!await which("nvidia-smi")) {
        console.error("WARNING: nvidia-smi not found. CUDA may not be available.");
    }
    if (!await which("nvcc")) missing.push("nvidia-cuda-toolkit");

    // Packaging
    if (!await which("patchelf")) missing.push("patchelf");

    // Streaming test deps
    if (!await which("pv")) missing.push("pv");
    if (!await which("nc") && !await which("ncat")) missing.push("ncat");

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
        console.error("Run: ./run");
        process.exit(1);
    }
}

// ─── Commands ──────────────────────────────────────────────────────────────

export async function build() {
    await ensureDeps();
    await ensureSubmodule();
    if (!process.env.CI) await ensureModels();
    console.log("Building...");
    await $`zig build`;
}

export async function rebuild() {
    await ensureDeps();
    await ensureSubmodule();
    await ensureModels();
    console.log("Rebuilding (forcing CMake + CUDA recompilation)...");
    await $`zig build -Dforce-cmake`;
}

export async function clean() {
    await $`rm -rf zig-out .zig-cache whisper.cpp/build-zig`;
    console.log("Cleaned.");
}

export async function setup() {
    await build();

    // Delegate permissions, audio detection, and service setup to install.sh
    const installSh = join(SCRIPT_DIR, "install.sh");
    await $`bash ${installSh} setup-dev ${SCRIPT_DIR}`;
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
    await $`rm -rf dist && mkdir -p dist/models`;

    // Copy binary
    await $`cp zig-out/bin/zigsper dist/`;

    // Fix RPATH so binary finds shared libs relative to itself
    await $`patchelf --set-rpath '$ORIGIN' dist/zigsper`;

    // Copy shared libs (with symlinks preserved)
    await $`bash -c "cp -a whisper.cpp/build-zig/*/lib*.so* dist/"`;

    // Copy install script
    await $`cp install.sh dist/`;

    // Summary
    const { stdout: fileCount } = await $`ls -1 dist/ | wc -l`.quiet();
    const { stdout: totalSize } = await $`du -sh dist/`.quiet();
    console.log(`dist/ ready: ${fileCount.toString().trim()} files, ${totalSize.toString().trim().split("\t")[0]}`);
}

export async function ci() {
    await ensureSubmodule();
    console.log("Running tests...");
    await $`zig build test`;
    console.log("Building...");
    await $`zig build -Dcmake-jobs=3`;
    console.log("Packaging...");
    await dist();
}

// ─── Command dispatch ──────────────────────────────────────────────────────

const commands: Record<string, Function> = {
    build, rebuild, clean, setup, test, dist, ci,
    "slow-test": slowTest,
};

const command = process.argv[2] || "build";
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

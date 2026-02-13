#!/usr/bin/env ./bootstrap.sh
import { $, spawn, file } from "bun";
import { existsSync, statSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const BINARY = "./zig-out/bin/whisper-dictate";
const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

async function hasGpu(): Promise<boolean> {
    const { exitCode } = await $`nvidia-smi`.quiet().nothrow();
    return exitCode === 0;
}

function tmpFile(prefix: string, ext: string): string {
    return join(tmpdir(), `${prefix}-${Date.now()}${ext}`);
}

/** Wait for a pattern to appear in a log file, or throw on timeout / process death. */
async function waitForLog(logFile: string, pattern: RegExp, proc: ReturnType<typeof spawn>, timeoutSec = 60): Promise<string> {
    const deadline = Date.now() + timeoutSec * 1000;
    while (Date.now() < deadline) {
        if (proc.exitCode !== null) {
            const log = await file(logFile).text().catch(() => "(empty)");
            throw new Error(`Server died during startup. Log:\n${log}`);
        }
        const text = await file(logFile).text().catch(() => "");
        const match = text.match(pattern);
        if (match) return match[0];
        await Bun.sleep(500);
    }
    const log = await file(logFile).text().catch(() => "(empty)");
    throw new Error(`Timed out waiting for ${pattern} after ${timeoutSec}s. Log:\n${log.slice(-2000)}`);
}

/** Start the whisper-dictate server with given args, wait for ready, return handle. */
async function startServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; port: number; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");

    const proc = spawn([BINARY, ...args], {
        stdout: Bun.file(logFile),
        stderr: Bun.file(logFile),
    });

    const kill = () => {
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        const line = await waitForLog(logFile, /Listening on port (\d+)/, proc);
        const port = parseInt(line.match(/\d+/)![0]);
        console.error(`Server ready on port ${port} (PID ${proc.pid})`);
        return { proc, port, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

/** Start the server in local PipeWire capture mode, wait for "Capturing audio". */
async function startLocalServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; outputFile: string; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");
    const outputFile = tmpFile("whisper-pw-stream", ".txt");

    const proc = spawn([BINARY, ...args], {
        stdout: Bun.file(outputFile),
        stderr: Bun.file(logFile),
    });

    const kill = () => {
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        await waitForLog(logFile, /Capturing audio/, proc);
        console.error(`Server capturing audio (PID ${proc.pid})`);
        return { proc, outputFile, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

// ─── Text comparison (from test-compare.sh) ────────────────────────────────

function normalize(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9' ]/g, " ").replace(/\s+/g, " ").trim();
}

function compareWords(streamWords: string[], refWords: string[]): { matched: number; total: number; coverage: string; missed: string[] } {
    let matched = 0;
    let streamIdx = 0;
    const missed: string[] = [];

    for (let r = 0; r < refWords.length; r++) {
        let found = false;
        for (let look = 0; look < 5 && streamIdx + look < streamWords.length; look++) {
            if (refWords[r] === streamWords[streamIdx + look]) {
                matched++;
                streamIdx = streamIdx + look + 1;
                found = true;
                break;
            }
        }
        if (!found) missed.push(refWords[r]);
    }

    const total = refWords.length;
    const coverage = total > 0 ? (matched * 100 / total).toFixed(1) : "0";
    return { matched, total, coverage, missed };
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

function ensureFile(path: string, label?: string) {
    if (!existsSync(path)) {
        console.error(`File not found: ${path}${label ? ` (${label})` : ""}`);
        process.exit(1);
    }
}

function wavDuration(path: string): string {
    const rawSize = statSync(path).size - 44;
    return (rawSize / 32000).toFixed(1);
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

export async function testStream(wavFile = "jfk.wav") {
    ensureBinary();
    ensureFile(wavFile);
    if (!await hasGpu()) { console.log("Skipping: no CUDA-capable GPU detected"); return; }

    const duration = wavDuration(wavFile);
    const timeoutMs = (parseFloat(duration) + 30) * 1000; // audio duration + 30s for startup/flush

    const server = await startServer(["--port", "0", "--verbose"]);
    try {
        console.error(`Streaming ${wavFile} (${duration}s, timeout ${(timeoutMs / 1000).toFixed(0)}s) to localhost:${server.port}...`);
        // Skip 44-byte WAV header, send at 32000 bytes/sec (16kHz S16 mono)
        await Promise.race([
            $`tail -c +45 ${wavFile} | pv -qL 32000 | nc -q 5 localhost ${server.port}`.nothrow(),
            Bun.sleep(timeoutMs).then(() => { throw new Error(`Test timed out after ${timeoutMs / 1000}s`); }),
        ]);
    } finally {
        server.kill();
    }
}

export async function testPwStream(wavFile = "jfk.wav") {
    ensureBinary();
    ensureFile(wavFile);
    if (!await hasGpu()) { console.log("Skipping: no CUDA-capable GPU detected"); return; }

    const duration = wavDuration(wavFile);
    const LOOPBACK_SINK = "test-whisper-loopback-sink";
    const LOOPBACK_SOURCE = "test-whisper-loopback-source";

    // Start pw-loopback: creates a virtual sink + source bridge
    const loopback = spawn([
        "pw-loopback",
        `--capture-props=media.class=Audio/Sink node.name=${LOOPBACK_SINK}`,
        `--playback-props=media.class=Audio/Source node.name=${LOOPBACK_SOURCE}`,
        "-C", "1", "-m", "MONO",
    ], { stdout: "ignore", stderr: "ignore" });

    await Bun.sleep(1000);

    // Verify loopback created the source node
    const { exitCode: linkCheck } = await $`pw-link -o 2>/dev/null | grep -q ${LOOPBACK_SOURCE}`.quiet().nothrow();
    if (linkCheck !== 0) {
        loopback.kill();
        console.error("Failed to create PipeWire loopback. Is PipeWire running?");
        process.exit(1);
    }

    const server = await startLocalServer([
        "--input", "local",
        "--pw-target", LOOPBACK_SOURCE,
        "--pw-channel", "MONO",
        "--verbose",
    ]);

    try {
        console.error(`Streaming ${wavFile} (${duration}s) via PipeWire...`);

        // Play WAV through the loopback sink (pw-cat handles real-time pacing)
        const pwcat = spawn([
            "pw-cat", "-p",
            `--target=${LOOPBACK_SINK}`,
            "--rate=16000", "--channels=1", "--format=s16",
            wavFile,
        ], { stdout: "ignore", stderr: "ignore" });

        // Wait for playback to finish
        await pwcat.exited;

        // Give the server time to flush trailing transcription
        await Bun.sleep(3000);

        // Show results
        const output = await file(server.outputFile).text();
        console.error("");
        console.error("=== Streaming Output ===");
        console.error(output);

        const wordCount = output.split("\n").filter(Boolean)
            .map(line => line.split("\t").slice(1).join("\t"))
            .join(" ").split(/\s+/).filter(Boolean).length;
        console.error(`\nTotal words emitted: ${wordCount}`);
    } finally {
        server.kill();
        loopback.kill();
    }
}

export async function testLongStream() {
    ensureBinary();
    ensureFile("jfk.wav");
    if (!await hasGpu()) { console.log("Skipping: no CUDA-capable GPU detected"); return; }

    const rawPcm = tmpFile("whisper-test", ".raw");
    const LOOPS = 20;

    // Extract raw PCM (skip 44-byte WAV header)
    await $`tail -c +45 jfk.wav > ${rawPcm}`;
    const rawSize = statSync(rawPcm).size;
    const durationPerLoop = (rawSize / 32000).toFixed(1);
    const totalDuration = (rawSize * LOOPS / 32000).toFixed(1);

    const server = await startServer(["--port", "0", "--verbose"]);

    try {
        console.error(`Raw PCM: ${rawSize} bytes per loop (${durationPerLoop}s)`);
        console.error(`Streaming ${LOOPS} loops = ${totalDuration}s to localhost:${server.port}`);
        console.error("---");

        // Concatenate N loops of raw PCM, pipe at real-time rate
        const loopCmd = Array.from({ length: LOOPS }, () => `cat ${rawPcm}`).join("; ");
        await $`bash -c ${`(${loopCmd}) | pv -qL 32000 | nc -q 5 localhost ${server.port}`}`;

        console.error("---");
        console.error("Done.");
    } finally {
        server.kill();
        await $`rm -f ${rawPcm}`.nothrow();
    }
}

export async function testCompare(name = "long-recording") {
    ensureBinary();
    if (!await hasGpu()) { console.log("Skipping: no CUDA-capable GPU detected"); return; }
    const wav = `testdata/${name}.wav`;
    const ref = `testdata/${name}.txt`;
    ensureFile(wav);
    ensureFile(ref, "reference transcript");

    const duration = wavDuration(wav);
    const streamOutput = tmpFile("whisper-compare", ".txt");

    const server = await startServer(["--port", "0", "--verbose"]);

    try {
        console.error("=== Streaming Comparison Test ===");
        console.error(`Audio: ${wav} (${duration}s)`);
        console.error(`Reference: ${ref}`);
        console.error(`Server: localhost:${server.port}`);
        console.error("");
        console.error("Streaming at real-time rate...");

        await $`tail -c +45 ${wav} | pv -qL 32000 | nc -q 1 localhost ${server.port} > ${streamOutput}`;

        const rawOutput = await file(streamOutput).text();
        console.error("");
        console.error("=== Raw Streaming Output ===");
        console.error(rawOutput);

        // Extract text (strip timestamp prefix), join into single line
        const streamText = rawOutput.split("\n").filter(Boolean)
            .map(line => line.split("\t").slice(1).join("\t"))
            .join(" ").replace(/\s+/g, " ").trim();

        const refText = await file(ref).text();

        const normRef = normalize(refText);
        const normStream = normalize(streamText);

        const refWords = normRef.split(" ").filter(Boolean);
        const streamWords = normStream.split(" ").filter(Boolean);

        console.error("");
        console.error("=== Word Comparison ===");
        console.error(`Reference words: ${refWords.length}`);
        console.error(`Streamed words:  ${streamWords.length}`);

        const result = compareWords(streamWords, refWords);

        console.error("");
        console.error("=== Results ===");
        console.error(`Matched: ${result.matched} / ${result.total} words (${result.coverage}%)`);
        console.error(`Missed:  ${result.missed.length} words`);

        if (result.missed.length > 0) {
            console.error("");
            console.error("Missed words:");
            for (const w of result.missed) console.error(`  ${w}`);
        }

        // Emission timeline
        console.error("");
        console.error("=== Emission Timeline ===");
        for (const line of rawOutput.split("\n").filter(Boolean)) {
            const [timestamp, ...rest] = line.split("\t");
            const text = rest.join("\t");
            const wc = text.split(/\s+/).filter(Boolean).length;
            console.error(`  ${timestamp}s  (+${wc}w)  ${text}`);
        }

        console.error("");
        console.error("=== Summary ===");
        console.error(`Coverage: ${result.coverage}% (${result.matched}/${result.total})`);
        console.error(`Duration: ${duration}s`);

        // Machine-readable summary to stdout
        console.log(`${result.matched}/${result.total} ${result.coverage}%`);
    } finally {
        server.kill();
        await $`rm -f ${streamOutput}`.nothrow();
    }
}

export async function test() {
    await $`zig build test`;
}

export async function dist() {
    ensureBinary();
    await $`rm -rf dist && mkdir -p dist/models`;

    // Copy binary
    await $`cp zig-out/bin/whisper-dictate dist/`;

    // Fix RPATH so binary finds shared libs relative to itself
    await $`patchelf --set-rpath '$ORIGIN' dist/whisper-dictate`;

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
    if (await hasGpu()) {
        console.log("Building...");
        await $`zig build -Dcmake-jobs=3`;
        console.log("Packaging...");
        await dist();
    } else {
        console.log("No GPU detected — skipping full build and packaging.");
    }
}

// ─── Command dispatch ──────────────────────────────────────────────────────

const commands: Record<string, Function> = {
    build, rebuild, clean, setup, test, dist, ci,
    "test-stream": testStream,
    "test-pw-stream": testPwStream,
    "test-long-stream": testLongStream,
    "test-compare": testCompare,
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

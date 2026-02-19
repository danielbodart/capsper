import { $, spawn, file } from "bun";
import { expect } from "bun:test";
import { existsSync, readFileSync, statSync, mkdirSync, copyFileSync } from "fs";
import { createConnection } from "net";
import { tmpdir } from "os";
import { join } from "path";

export const BINARY = "./dist/bin/capsper";
export const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
export const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
export const WARMUP_FILE = "test/jfk.wav";

// Track all spawned child processes so we can kill them on exit/signal.
// Prevents orphaned capsper processes holding GPU memory after Ctrl+C.
const childProcs = new Set<ReturnType<typeof spawn>>();

function killAllChildren() {
    for (const proc of childProcs) {
        try { proc.kill(); } catch {}
        try { proc.kill(9); } catch {}
    }
    childProcs.clear();
}

process.on("exit", killAllChildren);
process.on("SIGINT", () => { killAllChildren(); process.exit(1); });
process.on("SIGTERM", () => { killAllChildren(); process.exit(1); });

export function trackProc(proc: ReturnType<typeof spawn>): void {
    childProcs.add(proc);
    proc.exited.then(() => childProcs.delete(proc));
}

export async function hasGpu(): Promise<boolean> {
    const { exitCode } = await $`nvidia-smi`.quiet().nothrow();
    return exitCode === 0;
}

export function tmpFile(prefix: string, ext: string): string {
    return join(tmpdir(), `${prefix}-${Date.now()}${ext}`);
}

/** Wait for a pattern to appear in a log file, or throw on timeout / process death. */
export async function waitForLog(logFile: string, pattern: RegExp, proc: ReturnType<typeof spawn>, timeoutSec = 60): Promise<string> {
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

/** Start the capsper server with given args, wait for ready, return handle. */
export async function startServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; port: number; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");

    const proc = spawn([BINARY, "--warmup-file", WARMUP_FILE, ...args], {
        stdout: Bun.file(logFile),
        stderr: Bun.file(logFile),
    });
    trackProc(proc);

    const kill = () => {
        childProcs.delete(proc);
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        // 180s timeout: first-time CUDA PTX compilation during warmup can take minutes
        const line = await waitForLog(logFile, /Listening on port (\d+)/, proc, 180);
        const port = parseInt(line.match(/\d+/)![0]);
        console.error(`Server ready on port ${port} (PID ${proc.pid})`);
        return { proc, port, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

/** Start the server in local PipeWire capture mode, wait for "Capturing audio". */
export async function startLocalServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; outputFile: string; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");
    const outputFile = tmpFile("whisper-pw-stream", ".txt");

    const proc = spawn([BINARY, "--warmup-file", WARMUP_FILE, ...args], {
        stdout: Bun.file(outputFile),
        stderr: Bun.file(logFile),
    });
    trackProc(proc);

    const kill = () => {
        childProcs.delete(proc);
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        // 180s timeout: first-time CUDA PTX compilation during warmup can take minutes
        await waitForLog(logFile, /Capturing audio/, proc, 180);
        console.error(`Server capturing audio (PID ${proc.pid})`);
        return { proc, outputFile, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

export function normalize(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9' ]/g, " ").replace(/\s+/g, " ").trim();
}

export function compareWords(streamWords: string[], refWords: string[]): { matched: number; total: number; coverage: string; missed: string[] } {
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

export function ensureFile(path: string, label?: string): void {
    if (!existsSync(path)) {
        throw new Error(`File not found: ${path}${label ? ` (${label})` : ""}`);
    }
}

export function ensureBinary(): void {
    if (!existsSync(BINARY)) {
        throw new Error(`Binary not found: ${BINARY} — run ./run.ts first`);
    }
}

export function wavDuration(path: string): string {
    const rawSize = statSync(path).size - 44;
    return (rawSize / 32000).toFixed(1);
}

/** Read a WAV file, strip the 44-byte header, return raw PCM buffer. */
export function readPcm(wavFile: string): Buffer {
    return readFileSync(wavFile).subarray(44);
}

/** Stream PCM data to a TCP server at real-time rate, return server response.
 *  Sends ~100ms chunks at 32000 bytes/sec, then shuts down the write side
 *  so the server sees EOF immediately and flushes. */
export function streamPcm(port: number, pcm: Buffer, bytesPerSec = 32000): Promise<string> {
    return new Promise((resolve, reject) => {
        const socket = createConnection(port, "localhost");
        const chunks: Buffer[] = [];
        const CHUNK_MS = 100;
        const CHUNK_BYTES = Math.ceil(bytesPerSec * CHUNK_MS / 1000);
        let offset = 0;
        let timer: ReturnType<typeof setTimeout>;

        socket.on("connect", () => {
            const sendNext = () => {
                if (offset >= pcm.length) {
                    socket.end();
                    return;
                }
                const end = Math.min(offset + CHUNK_BYTES, pcm.length);
                socket.write(pcm.subarray(offset, end));
                offset = end;
                timer = setTimeout(sendNext, CHUNK_MS);
            };
            sendNext();
        });

        socket.on("data", (data) => chunks.push(data));
        socket.on("end", () => resolve(Buffer.concat(chunks).toString()));
        socket.on("error", (err) => { clearTimeout(timer); reject(err); });
    });
}

/** Stream all PCM in one write + half-close. No real-time pacing.
 *  Uses Bun.connect with explicit shutdown() for proper TCP half-close. */
export function streamPcmFast(port: number, pcm: Buffer): Promise<string> {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let remaining: Buffer | null = null;
        let shutdownPending = false;

        Bun.connect({
            hostname: "localhost",
            port,
            socket: {
                open(socket) {
                    const written = socket.write(pcm);
                    if (written < pcm.length) {
                        remaining = pcm.subarray(written);
                    } else {
                        socket.shutdown();
                    }
                },
                drain(socket) {
                    if (remaining) {
                        const written = socket.write(remaining);
                        if (written >= remaining.length) {
                            remaining = null;
                            socket.shutdown();
                        } else {
                            remaining = remaining.subarray(written);
                        }
                    }
                },
                data(_socket, data) {
                    chunks.push(Buffer.from(data));
                },
                close() {
                    resolve(Buffer.concat(chunks).toString());
                },
                connectError(_socket, err) {
                    reject(err);
                },
                error(_socket, err) {
                    reject(err);
                },
            },
        });
    });
}

export interface Emission {
    time: number;
    text: string;
}

/** Parse "timestamp\ttext\n" lines from server output. */
export function parseEmissions(rawOutput: string): Emission[] {
    return rawOutput.split("\n").filter(Boolean).map(line => {
        const [ts, ...rest] = line.split("\t");
        return { time: parseFloat(ts), text: rest.join("\t") };
    });
}

/** Find the maximum gap between consecutive emissions. */
export function analyzeGaps(emissions: Emission[]): { maxGapSec: number; maxGapAfterText: string } {
    let maxGapSec = 0;
    let maxGapAfterText = "";
    for (let i = 1; i < emissions.length; i++) {
        const gap = emissions[i].time - emissions[i - 1].time;
        if (gap > maxGapSec) {
            maxGapSec = gap;
            maxGapAfterText = emissions[i].text.trim();
        }
    }
    return { maxGapSec, maxGapAfterText };
}

/** Find consecutive repeated words. Returns occurrences with count >= threshold. */
export function detectRepetitions(words: string[], threshold = 5): { word: string; count: number }[] {
    const results: { word: string; count: number }[] = [];
    let i = 0;
    while (i < words.length) {
        let count = 1;
        while (i + count < words.length && words[i + count] === words[i]) count++;
        if (count >= threshold) {
            results.push({ word: words[i], count });
        }
        i += count;
    }
    return results;
}

export interface Thresholds {
    minCoverage?: number;
    maxMissed?: number;
    maxExtras?: number;
    maxGapSec?: number;
    maxRepetitions?: number;
}

const DEFAULT_THRESHOLDS: Required<Thresholds> = {
    minCoverage: 85,
    maxMissed: 25,
    maxExtras: 15,
    maxGapSec: 10,
    maxRepetitions: 5,
};

export interface TranscriptResult {
    streamText: string;
    streamWords: string[];
    emissions: Emission[];
    coverage?: number;
    matched?: number;
    total?: number;
    missed?: string[];
    extras?: number;
    maxGapSec: number;
    repetitions: { word: string; count: number }[];
}

/** Universal assertion function for transcript quality. */
export function assertTranscript(
    rawOutput: string,
    refText: string | null,
    thresholds: Thresholds | undefined,
    label: string,
): TranscriptResult {
    const t = { ...DEFAULT_THRESHOLDS, ...thresholds };
    const emissions = parseEmissions(rawOutput);
    const streamText = emissions.map(e => e.text).join(" ").replace(/\s+/g, " ").trim();
    const streamWords = normalize(streamText).split(" ").filter(Boolean);

    // Gap analysis
    const { maxGapSec, maxGapAfterText } = analyzeGaps(emissions);

    // Repetition detection
    const repetitions = detectRepetitions(streamWords, t.maxRepetitions);

    const result: TranscriptResult = {
        streamText, streamWords, emissions, maxGapSec, repetitions,
    };

    // Emission timeline
    console.error(`\n=== ${label} ===`);
    for (const e of emissions) {
        console.error(`  ${e.time.toFixed(1)}s  ${e.text}`);
    }

    if (refText) {
        const refWords = normalize(refText).split(" ").filter(Boolean);
        const cmp = compareWords(streamWords, refWords);
        const extras = streamWords.length - cmp.matched;
        const coverage = parseFloat(cmp.coverage);

        result.coverage = coverage;
        result.matched = cmp.matched;
        result.total = cmp.total;
        result.missed = cmp.missed;
        result.extras = extras;

        console.error(`Coverage: ${cmp.coverage}% (${cmp.matched}/${cmp.total}), extras: ${extras}, gap: ${maxGapSec.toFixed(1)}s`);
        if (cmp.missed.length > 0) {
            console.error(`Missed: ${cmp.missed.join(", ")}`);
        }
        if (repetitions.length > 0) {
            console.error(`Repetitions: ${repetitions.map(r => `"${r.word}" x${r.count}`).join(", ")}`);
        }

        // Assertions
        expect(coverage).toBeGreaterThanOrEqual(t.minCoverage);
        expect(cmp.missed.length).toBeLessThanOrEqual(t.maxMissed);
        expect(extras).toBeLessThanOrEqual(t.maxExtras);
    } else {
        console.error(`Words: ${streamWords.length}, gap: ${maxGapSec.toFixed(1)}s`);
        // Smoke test: must produce output
        expect(streamWords.length).toBeGreaterThan(0);
    }

    // Gap + repetition assertions always apply
    if (emissions.length > 1) {
        expect(maxGapSec).toBeLessThanOrEqual(t.maxGapSec);
    }
    expect(repetitions.length).toBe(0);

    return result;
}

/** Display word-level diff using git diff --word-diff. Display-only, not for assertions. */
export async function wordDiff(streamText: string, refText: string): Promise<void> {
    const streamFile = tmpFile("stream", ".txt");
    const refFile = tmpFile("ref", ".txt");
    await Bun.write(streamFile, normalize(streamText));
    await Bun.write(refFile, normalize(refText));

    const result = await $`git diff --word-diff --no-index ${refFile} ${streamFile}`.quiet().nothrow();
    if (result.stdout.length > 0) {
        console.error("\n=== Word Diff (ref → stream) ===");
        console.error(result.stdout.toString());
    }
}

/** Save server log to test/results/<name>.log */
export function saveLog(logFile: string, name: string): void {
    const dir = "test/results";
    mkdirSync(dir, { recursive: true });
    try {
        copyFileSync(logFile, join(dir, `${name}.log`));
    } catch {}
}

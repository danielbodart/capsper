import { $, spawn, file } from "bun";
import { expect } from "bun:test";
import { existsSync, readFileSync, writeFileSync, statSync, mkdirSync, copyFileSync } from "fs";

import { tmpdir } from "os";
import { join } from "path";

const IS_MACOS = process.platform === "darwin";
export const BINARY = IS_MACOS ? "./dist/macos/bin/capsper" : "./dist/linux/bin/capsper";

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
    if (process.platform === "darwin") {
        // macOS: check for Metal GPU via system_profiler
        const { exitCode } = await $`system_profiler SPDisplaysDataType 2>/dev/null | grep -q Metal`.quiet().nothrow();
        return exitCode === 0;
    }
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
    const logFile = tmpFile("capsper-server", ".log");

    const proc = spawn([BINARY, ...args], {
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
    const logFile = tmpFile("capsper-server", ".log");
    const outputFile = tmpFile("capsper-pw-stream", ".txt");

    const proc = spawn([BINARY, ...args], {
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

export type EditOp = "match" | "sub" | "ins" | "del";

export interface EditResult {
    ops: EditOp[];
    refAlign: (string | null)[];   // null for insertions
    streamAlign: (string | null)[]; // null for deletions
    matches: number;
    substitutions: number;
    insertions: number;
    deletions: number;
}

/** Wagner-Fischer word-level edit distance with backtrace.
 *  Returns optimal alignment with distinct match/sub/ins/del counts.
 *  Follows standard WER convention: ins = extra stream word, del = missing ref word. */
export function wordEditDistance(refWords: string[], streamWords: string[]): EditResult {
    const m = refWords.length;
    const n = streamWords.length;

    // dp[i][j] = min edits to align ref[0..i) with stream[0..j)
    const dp: number[][] = Array.from({ length: m + 1 }, () => new Array(n + 1));
    dp[0][0] = 0;
    for (let i = 1; i <= m; i++) dp[i][0] = i;  // delete all ref words
    for (let j = 1; j <= n; j++) dp[0][j] = j;  // insert all stream words

    for (let i = 1; i <= m; i++) {
        for (let j = 1; j <= n; j++) {
            if (refWords[i - 1] === streamWords[j - 1]) {
                dp[i][j] = dp[i - 1][j - 1]; // match (free)
            } else {
                dp[i][j] = Math.min(
                    dp[i - 1][j - 1] + 1, // substitution
                    dp[i][j - 1] + 1,      // insertion (extra stream word)
                    dp[i - 1][j] + 1,      // deletion (missed ref word)
                );
            }
        }
    }

    // Backtrace to build alignment
    const ops: EditOp[] = [];
    const refAlign: (string | null)[] = [];
    const streamAlign: (string | null)[] = [];
    let i = m, j = n;

    while (i > 0 || j > 0) {
        if (i > 0 && j > 0 && refWords[i - 1] === streamWords[j - 1]) {
            ops.push("match");
            refAlign.push(refWords[i - 1]);
            streamAlign.push(streamWords[j - 1]);
            i--; j--;
        } else if (i > 0 && j > 0 && dp[i][j] === dp[i - 1][j - 1] + 1) {
            ops.push("sub");
            refAlign.push(refWords[i - 1]);
            streamAlign.push(streamWords[j - 1]);
            i--; j--;
        } else if (j > 0 && dp[i][j] === dp[i][j - 1] + 1) {
            ops.push("ins");
            refAlign.push(null);
            streamAlign.push(streamWords[j - 1]);
            j--;
        } else {
            ops.push("del");
            refAlign.push(refWords[i - 1]);
            streamAlign.push(null);
            i--;
        }
    }

    ops.reverse();
    refAlign.reverse();
    streamAlign.reverse();

    let matches = 0, substitutions = 0, insertions = 0, deletions = 0;
    for (const op of ops) {
        if (op === "match") matches++;
        else if (op === "sub") substitutions++;
        else if (op === "ins") insertions++;
        else deletions++;
    }

    return { ops, refAlign, streamAlign, matches, substitutions, insertions, deletions };
}

/** Render inline diff from edit alignment.
 *  Matched words shown as-is, [-deleted-], {+inserted+}, [~ref→stream~] */
export function formatAlignment(edit: EditResult): string {
    const parts: string[] = [];
    for (let i = 0; i < edit.ops.length; i++) {
        switch (edit.ops[i]) {
            case "match":
                parts.push(edit.refAlign[i]!);
                break;
            case "sub":
                parts.push(`[~${edit.refAlign[i]}→${edit.streamAlign[i]}~]`);
                break;
            case "ins":
                parts.push(`{+${edit.streamAlign[i]}+}`);
                break;
            case "del":
                parts.push(`[-${edit.refAlign[i]}-]`);
                break;
        }
    }
    return parts.join(" ");
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
 *  so the server sees EOF immediately and flushes.
 *  Uses Bun.connect (same as streamPcmFast) for consistent TCP half-close behavior. */
export function streamPcm(port: number, pcm: Buffer, bytesPerSec = 32000): Promise<string> {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        const CHUNK_MS = 100;
        const CHUNK_BYTES = Math.ceil(bytesPerSec * CHUNK_MS / 1000);
        let offset = 0;
        let timer: ReturnType<typeof setTimeout>;

        Bun.connect({
            hostname: "localhost",
            port,
            socket: {
                open(socket) {
                    const sendNext = () => {
                        if (offset >= pcm.length) {
                            socket.shutdown();
                            return;
                        }
                        const end = Math.min(offset + CHUNK_BYTES, pcm.length);
                        socket.write(pcm.subarray(offset, end));
                        offset = end;
                        timer = setTimeout(sendNext, CHUNK_MS);
                    };
                    sendNext();
                },
                data(_socket, data) {
                    chunks.push(Buffer.from(data));
                },
                close() {
                    resolve(Buffer.concat(chunks).toString());
                },
                connectError(_socket, err) {
                    clearTimeout(timer);
                    reject(err);
                },
                error(_socket, err) {
                    clearTimeout(timer);
                    reject(err);
                },
            },
        });
    });
}

/** Stream all PCM in one write + half-close. No real-time pacing.
 *  Uses Bun.connect with explicit shutdown() for proper TCP half-close. */
export function streamPcmFast(port: number, pcm: Buffer): Promise<string> {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let remaining: Buffer | null = null;

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

/** Stream a WAV file directly through the streaming pipeline via --stream-wav.
 *  Bypasses TCP and PipeWire entirely — the binary reads the WAV file and feeds
 *  PCM chunks through the same VAD → speech_buf → pipeline → trim code path.
 *  Produces deterministic, byte-for-byte identical processing to the live path. */
export async function streamWavDirect(
    wavFile: string,
    serverArgs: string[],
): Promise<{ output: string; logFile: string }> {
    const logFile = tmpFile("capsper-stream-wav", ".log");

    const proc = spawn([BINARY, "--stream-wav", wavFile, ...serverArgs], {
        stdout: "pipe",
        stderr: Bun.file(logFile),
    });
    trackProc(proc);

    const output = await new Response(proc.stdout).text();
    await proc.exited;
    return { output, logFile };
}

export interface Emission {
    time: number;
    text: string;
}

/** Parse emissions from server output.
 *  Raw text stream (no delimiters) — treat entire output as one emission. */
export function parseEmissions(rawOutput: string): Emission[] {
    if (rawOutput.trim().length === 0) return [];
    return [{ time: 0, text: rawOutput }];
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
    maxWer?: number;
    maxGapSec?: number;
    maxRepetitions?: number;
}

const DEFAULT_THRESHOLDS: Required<Thresholds> = {
    minCoverage: 90,
    maxWer: 30,
    maxGapSec: 10,
    maxRepetitions: 5,
};

export interface TranscriptResult {
    name: string;
    streamText: string;
    streamWords: string[];
    emissions: Emission[];
    coverage?: number;
    wer?: number;
    matches?: number;
    substitutions?: number;
    insertions?: number;
    deletions?: number;
    total?: number;
    maxGapSec: number;
    repetitions: { word: string; count: number }[];
    passed: boolean;
    error?: unknown;
    log: string;
}

/** Universal assertion function for transcript quality.
 *  Always populates and returns the result, even on assertion failure.
 *  Collects the first assertion error and throws it after returning the result
 *  via the caller's finally block. */
export function assertTranscript(
    rawOutput: string,
    refText: string | null,
    thresholds: Thresholds | undefined,
    label: string,
): TranscriptResult {
    const t = { ...DEFAULT_THRESHOLDS, ...thresholds };
    const emissions = parseEmissions(rawOutput);
    const streamText = emissions.map(e => e.text).join("").replace(/\s+/g, " ").trim();
    const streamWords = normalize(streamText).split(" ").filter(Boolean);

    // Gap analysis
    const { maxGapSec } = analyzeGaps(emissions);

    // Repetition detection
    const repetitions = detectRepetitions(streamWords, t.maxRepetitions);

    const lines: string[] = [];
    const log = (s: string) => lines.push(s);

    const result: TranscriptResult = {
        name: label, streamText, streamWords, emissions, maxGapSec, repetitions, passed: true, log: "",
    };

    // Emission timeline
    log(`\n=== ${label} ===`);
    for (const e of emissions) {
        log(`  ${e.time.toFixed(1)}s  ${e.text}`);
    }

    // Collect first assertion failure, throw after result is fully populated
    let firstError: unknown;
    const check = (fn: () => void) => {
        try { fn(); } catch (e) { result.passed = false; firstError ??= e; }
    };

    if (refText) {
        const refWords = normalize(refText).split(" ").filter(Boolean);
        const edit = wordEditDistance(refWords, streamWords);
        const total = refWords.length;
        const coverage = total > 0 ? edit.matches * 100 / total : 0;
        const wer = total > 0 ? (edit.substitutions + edit.insertions + edit.deletions) * 100 / total : 0;

        result.coverage = Math.round(coverage * 10) / 10;
        result.wer = Math.round(wer * 10) / 10;
        result.matches = edit.matches;
        result.substitutions = edit.substitutions;
        result.insertions = edit.insertions;
        result.deletions = edit.deletions;
        result.total = total;

        log(`Coverage: ${result.coverage}% (${edit.matches}/${total})  WER: ${result.wer}%  [S:${edit.substitutions} I:${edit.insertions} D:${edit.deletions}]  Gap: ${maxGapSec.toFixed(1)}s`);

        if (repetitions.length > 0) {
            log(`Repetitions: ${repetitions.map(r => `"${r.word}" x${r.count}`).join(", ")}`);
        }

        log(`\n--- Diff (ref vs stream) ---\n${formatAlignment(edit)}\n`);

        check(() => expect(result.coverage!).toBeGreaterThanOrEqual(t.minCoverage));
        check(() => expect(result.wer!).toBeLessThanOrEqual(t.maxWer));
    } else {
        log(`Words: ${streamWords.length}, gap: ${maxGapSec.toFixed(1)}s`);
        check(() => expect(streamWords.length).toBeGreaterThan(0));
    }

    // Gap + repetition assertions always apply
    if (emissions.length > 1) {
        check(() => expect(maxGapSec).toBeLessThanOrEqual(t.maxGapSec));
    }
    check(() => expect(repetitions.length).toBe(0));

    result.log = lines.join("\n");
    result.error = firstError;
    return result;
}

/** Print a scorecard table summarizing all test results in a group. */
export function printScorecard(results: TranscriptResult[]): void {
    if (results.length === 0) return;

    const pad = (s: string, w: number) => s + " ".repeat(Math.max(0, w - s.length));
    const padR = (s: string, w: number) => " ".repeat(Math.max(0, w - s.length)) + s;

    // Build data rows first to compute column widths
    const rows = results.map(r => {
        if (r.total != null) {
            return {
                name: r.name,
                cov: `${r.coverage}% (${r.matches}/${r.total})`,
                wer: `${r.wer}%`,
                subs: String(r.substitutions ?? 0),
                ins: String(r.insertions ?? 0),
                del: String(r.deletions ?? 0),
                gap: `${r.maxGapSec.toFixed(1)}s`,
                status: r.passed ? "Pass" : "FAIL",
            };
        }
        return {
            name: r.name, cov: "-", wer: "-", subs: "-", ins: "-", del: "-",
            gap: `${r.maxGapSec.toFixed(1)}s`, status: r.passed ? "Pass" : "FAIL",
        };
    });

    const w = {
        name: Math.max(4, ...rows.map(r => r.name.length)),
        cov: Math.max(8, ...rows.map(r => r.cov.length)),
        wer: Math.max(3, ...rows.map(r => r.wer.length)),
        subs: Math.max(4, ...rows.map(r => r.subs.length)),
        ins: Math.max(3, ...rows.map(r => r.ins.length)),
        del: Math.max(3, ...rows.map(r => r.del.length)),
        gap: Math.max(3, ...rows.map(r => r.gap.length)),
        stat: 6,
    };

    const header = `  ${pad("Test", w.name)}  ${pad("Coverage", w.cov)}  ${padR("WER", w.wer)}  ${padR("Subs", w.subs)}  ${padR("Ins", w.ins)}  ${padR("Del", w.del)}  ${padR("Gap", w.gap)}  ${pad("Status", w.stat)}`;
    const sep = "  " + "-".repeat(header.length - 2);

    console.error("\n" + sep);
    console.error(header);
    console.error(sep);

    for (const r of rows) {
        console.error(`  ${pad(r.name, w.name)}  ${pad(r.cov, w.cov)}  ${padR(r.wer, w.wer)}  ${padR(r.subs, w.subs)}  ${padR(r.ins, w.ins)}  ${padR(r.del, w.del)}  ${padR(r.gap, w.gap)}  ${r.status}`);
    }

    console.error(sep);
    console.error("  Logs: test/results/\n");
}

/** Save server log to test/results/<name>.log */
export function saveLog(logFile: string, name: string): void {
    const dir = "test/results";
    mkdirSync(dir, { recursive: true });
    try {
        copyFileSync(logFile, join(dir, `${name}.log`));
    } catch {}
}

/** Save scoring detail (emission timelines, diffs, metrics) to test/results/<name>-scoring.log */
export function saveScoring(results: TranscriptResult[], name: string): void {
    const dir = "test/results";
    mkdirSync(dir, { recursive: true });
    const content = results.map(r => r.log).join("\n\n");
    writeFileSync(join(dir, `${name}-scoring.log`), content);
}

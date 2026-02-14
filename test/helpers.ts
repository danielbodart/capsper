import { $, spawn, file } from "bun";
import { existsSync, readFileSync, statSync } from "fs";
import { createConnection } from "net";
import { tmpdir } from "os";
import { join } from "path";

export const BINARY = "./dist/bin/zigsper";
export const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
export const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";

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

/** Start the zigsper server with given args, wait for ready, return handle. */
export async function startServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; port: number; logFile: string; kill: () => void }> {
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
export async function startLocalServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; outputFile: string; logFile: string; kill: () => void }> {
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

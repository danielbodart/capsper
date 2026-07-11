import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { $, spawn, file } from "bun";
import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { basename, join } from "path";
import {
    hasGpu, ensureBinary, ensureFile,
    startServer, startLocalServer, readPcm,
    streamPcmFast, streamPcm, streamWavDirect,
    assertTranscript, printScorecard, saveLog, saveScoring,
    wavDuration, trackProc, waitForLog,
    type Thresholds, type TranscriptResult,
} from "./helpers";

const gpu = await hasGpu();

// --- Test mode: tcp (default), tcp-realtime, pipewire, stream-wav ---
type TestMode = "tcp" | "tcp-realtime" | "pipewire" | "stream-wav";
const testMode: TestMode = (() => {
    const m = process.env.CAPSPER_TEST_MODE ?? "stream-wav";
    if (m !== "tcp" && m !== "tcp-realtime" && m !== "pipewire" && m !== "stream-wav") {
        throw new Error(`Invalid CAPSPER_TEST_MODE: ${m} (expected tcp|tcp-realtime|pipewire|stream-wav)`);
    }
    return m;
})();

console.error(`Test mode: ${testMode}`);

// --- WAV dir override (for gain experiments etc) ---
const wavDir = process.env.TEST_WAV_DIR ?? "test";
const wavPath = (name: string) => `${wavDir}/${name}.wav`;

// --- Extra server args from env ---
const dropTerms = process.env.DROP_TERMS ?? "test/drop-terms-nemotron.txt";
const extraServerArgs: string[] = [
    ...(process.env.ASR_MODEL ? ["--model", process.env.ASR_MODEL] : []),
    "--drop-terms", dropTerms,
];

// --- Load test cases from .test.json files ---
interface TestCaseConfig {
    group: "short" | "medium" | "long";
    thresholds?: Thresholds;
    serverArgs?: string[];
}

interface TestCase {
    name: string;
    group: string;
    wav: string;
    ref: string | null;
    thresholds?: Thresholds;
    serverArgs?: string[];
    durationSec: number;
}

function loadTestCases(): TestCase[] {
    const jsonFiles = readdirSync("test").filter(f => f.endsWith(".test.json")).sort();
    return jsonFiles.map(f => {
        const name = basename(f, ".test.json");
        const config: TestCaseConfig = JSON.parse(readFileSync(join("test", f), "utf-8"));
        const wav = wavPath(name);
        const refPath = `test/${name}.txt`;
        const ref = existsSync(refPath) ? refPath : null;
        const rawSize = existsSync(wav) ? statSync(wav).size - 44 : 0;
        const durationSec = rawSize / 32000;
        return { name, group: config.group, wav, ref, thresholds: config.thresholds, serverArgs: config.serverArgs, durationSec };
    });
}

const allCases = loadTestCases();

// --- Gating: which groups to run ---
const group = process.env.TEST_GROUP;
const testCase = process.env.TEST_CASE; // single test filter
const runShort = !group || group === "short" || !!process.env.SLOW_TESTS;
const runMedium = group === "medium" || !!process.env.SLOW_TESTS;
const runLong = group === "long" || !!process.env.SLOW_TESTS;
function shouldRunGroup(g: string): boolean {
    if (testCase) return true; // TEST_CASE overrides group gating
    switch (g) {
        case "short": return runShort;
        case "medium": return runMedium;
        case "long": return runLong;
        default: return false;
    }
}

// --- Group cases and collect server args per group ---
interface GroupConfig {
    name: string;
    cases: TestCase[];
    serverArgs: string[];
}

function buildGroups(): GroupConfig[] {
    const grouped = new Map<string, TestCase[]>();
    for (const tc of allCases) {
        if (testCase && tc.name !== testCase) continue;
        if (!shouldRunGroup(tc.group)) continue;

        const g = tc.group;
        if (!grouped.has(g)) grouped.set(g, []);
        grouped.get(g)!.push(tc);
    }

    const result: GroupConfig[] = [];
    for (const [name, cases] of grouped) {
        // Merge serverArgs from all cases in the group
        const serverArgs: string[] = [];
        for (const c of cases) {
            if (c.serverArgs) {
                for (const arg of c.serverArgs) {
                    if (!serverArgs.includes(arg)) serverArgs.push(arg);
                }
            }
        }
        result.push({ name, cases, serverArgs });
    }

    return result;
}

// --- Timeout calculation ---
function testTimeout(tc: TestCase): number {
    if (testMode === "tcp") {
        // Fast mode: flat timeout — processing is GPU-bound, not audio-bound
        return 120_000;
    }
    // Real-time modes: WAV duration + 30s headroom (in ms)
    return Math.ceil((tc.durationSec + 30) * 1000);
}

// --- PipeWire streaming ---
const LOOPBACK_SINK = "test-capsper-loopback-sink";
const LOOPBACK_SOURCE = "test-capsper-loopback-source";

/** Stream a WAV file via PipeWire loopback, return transcript output.
 *  Creates a fresh loopback + server per call. When pw-cat finishes playing,
 *  killing the loopback destroys the PipeWire source node, which triggers
 *  a stream error on the server's capture → pipe EOF → clean shutdown. */
async function streamPcmPipeWire(
    serverArgs: string[],
    wavFile: string,
): Promise<{ output: string; logFile: string }> {
    console.error(`  Streaming ${wavFile} (${wavDuration(wavFile)}s) via PipeWire...`);

    // Create a fresh loopback for this test.
    // audio.rate=16000 prevents PipeWire from resampling 16kHz→48kHz→16kHz
    // through the graph, which degrades SNR by ~11dB.
    const loopback = spawn([
        "pw-loopback",
        `--capture-props={"media.class":"Audio/Sink", "node.name":"${LOOPBACK_SINK}", "audio.rate":16000}`,
        `--playback-props={"media.class":"Audio/Source", "node.name":"${LOOPBACK_SOURCE}", "audio.rate":16000}`,
        "-C", "1", "-m", "MONO",
    ], { stdout: "ignore", stderr: "ignore" });
    trackProc(loopback);
    await Bun.sleep(500); // let PipeWire register the nodes

    const server = await startLocalServer([
        "--audio-target", LOOPBACK_SOURCE,
        "--audio-channel", "MONO",
        "--on-device-lost", "exit",
        ...serverArgs,
    ]);

    try {
        const pwcat = spawn([
            "pw-cat", "-p",
            `--target=${LOOPBACK_SINK}`,
            "--rate=16000", "--channels=1", "--format=s16",
            wavFile,
        ], { stdout: "ignore", stderr: "ignore" });
        trackProc(pwcat);

        await pwcat.exited;

        // Kill loopback → hotplug monitor closes audio pipe → clean EOF exit.
        try { loopback.kill(); } catch {}
        await Bun.sleep(500);

        await waitForLog(server.logFile, /session ended/, server.proc, 10);

        const output = await file(server.outputFile).text();
        return { output, logFile: server.logFile };
    } finally {
        try { loopback.kill(); } catch {}
        server.kill();
    }
}

// --- Run groups ---
const groups = buildGroups();

for (const g of groups) {
    describe.skipIf(!gpu)(`${g.name} regressions (${testMode})`, () => {
        let tcpServer: Awaited<ReturnType<typeof startServer>> | null = null;
        const results: TranscriptResult[] = [];
        const serverArgs = [
            "--verbose",
            ...g.serverArgs,
            ...extraServerArgs,
            // PipeWire test mode: disable auto-gain since audio is pre-recorded
            ...(testMode === "pipewire" ? ["--no-auto-gain"] : []),
        ];

        beforeAll(async () => {
            ensureBinary();
            for (const c of g.cases) {
                ensureFile(c.wav);
                if (c.ref) ensureFile(c.ref, "reference transcript");
            }

            if (testMode !== "pipewire" && testMode !== "stream-wav") {
                tcpServer = await startServer(["--port", "0", ...serverArgs]);
            }
        });

        afterAll(() => {
            const label = testCase ? `${g.name}-${testCase}-${testMode}` : `${g.name}-${testMode}`;
            if (results.length > 0) {
                saveScoring(results, label);
                printScorecard(results);
            }
            if (tcpServer) {
                saveLog(tcpServer.logFile, label);
                tcpServer.kill();
            }
        });

        for (const tc of g.cases) {
            test(tc.name, async () => {
                let output: string;

                if (testMode === "stream-wav") {
                    // Direct WAV: bypasses TCP/PipeWire, feeds file fd through streaming pipeline
                    const sw = await streamWavDirect(tc.wav, serverArgs);
                    output = sw.output;
                    saveLog(sw.logFile, `${tc.name}-${testMode}`);
                } else if (testMode === "pipewire") {
                    // PipeWire: fresh server per test (no connection-level isolation)
                    const pw = await streamPcmPipeWire(serverArgs, tc.wav);
                    output = pw.output;
                    saveLog(pw.logFile, `${tc.name}-${testMode}`);
                } else {
                    const pcm = readPcm(tc.wav);
                    if (testMode === "tcp-realtime") {
                        output = await streamPcm(tcpServer!.port, pcm);
                    } else {
                        output = await streamPcmFast(tcpServer!.port, pcm);
                    }
                }

                expect(output.length).toBeGreaterThan(0);
                const refText = tc.ref ? await file(tc.ref).text() : null;
                const result = assertTranscript(output, refText, tc.thresholds, tc.name);
                results.push(result);
                if (result.error) throw result.error;
            }, testTimeout(tc));
        }
    });
}

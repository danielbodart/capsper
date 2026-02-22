import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { file } from "bun";
import {
    hasGpu, ensureBinary, ensureFile,
    startServer, readPcm, streamPcmFast, assertTranscript,
    printScorecard, saveLog, saveScoring, type Thresholds, type TranscriptResult,
} from "./helpers";

const gpu = await hasGpu();

// TEST_WAV_DIR overrides WAV source directory (e.g. test/gained/ for gain experiments)
const wavDir = process.env.TEST_WAV_DIR ?? "test";
const wav = (name: string) => `${wavDir}/${name}.wav`;

interface TestCase {
    name: string;
    wav: string;
    ref: string | null;
    thresholds?: Thresholds;
}

const shortCases: TestCase[] = [
    { name: "jfk", wav: wav("jfk"), ref: "test/jfk.txt", thresholds: { minCoverage: 100, maxWer: 0 } },
    { name: "fully-committed", wav: wav("fully-committed"), ref: "test/fully-committed.txt", thresholds: { minCoverage: 100, maxWer: 0 } },
    { name: "working-test", wav: wav("working-test"), ref: "test/working-test.txt", thresholds: { minCoverage: 94, maxWer: 6 } },
    { name: "queued-fix", wav: wav("queued-fix"), ref: "test/queued-fix.txt", thresholds: { minCoverage: 100, maxWer: 0 } },
];

const mediumCases: TestCase[] = [
    { name: "long-pause", wav: wav("long-pause"), ref: "test/long-pause.txt", thresholds: { minCoverage: 85, maxWer: 20, maxGapSec: 4 } },
    { name: "repetition-loop", wav: wav("repetition-loop"), ref: "test/repetition-loop.txt", thresholds: { minCoverage: 85, maxWer: 15 } },
];

const longCases: TestCase[] = [
    { name: "dictation", wav: wav("dictation"), ref: "test/dictation.txt" },
    // Long recordings with pauses: sliding window trims degrade context beyond 30s.
    // long-recording has 20s silences causing hallucination in the second half.
    { name: "long-recording", wav: wav("long-recording"), ref: "test/long-recording.txt", thresholds: { minCoverage: 20, maxWer: 80 } },
    { name: "repetition-loop-long", wav: wav("repetition-loop-long"), ref: "test/repetition-loop-long.txt", thresholds: { minCoverage: 70, maxWer: 35 } },
    // 2min recording with silences. Streaming hallucinates ~85-word duplication after trailing silence at ~5min mark.
    { name: "silence-hallucination", wav: wav("silence-hallucination"), ref: "test/silence-hallucination.txt", thresholds: { minCoverage: 20, maxWer: 500, maxGapSec: 15 } },
];

// Gating: which groups to run
const group = process.env.TEST_GROUP;
const runShort = !group || group === "short" || !!process.env.SLOW_TESTS;
const runMedium = group === "medium" || !!process.env.SLOW_TESTS;
const runLong = group === "long" || !!process.env.SLOW_TESTS;

function runGroup(
    groupName: string,
    cases: TestCase[],
    shouldRun: boolean,
    serverArgs: string[],
    timeoutMs: number,
) {
    describe.skipIf(!gpu || !shouldRun)(`${groupName} regressions`, () => {
        let server: Awaited<ReturnType<typeof startServer>>;
        const results: TranscriptResult[] = [];

        beforeAll(async () => {
            ensureBinary();
            for (const c of cases) {
                ensureFile(c.wav);
                if (c.ref) ensureFile(c.ref, "reference transcript");
            }
            server = await startServer(["--port", "0", "--verbose", ...serverArgs]);
        });

        afterAll(() => {
            if (results.length > 0) {
                saveScoring(results, groupName);
                printScorecard(results);
            }
            if (server) {
                saveLog(server.logFile, groupName);
                server.kill();
            }
        });

        for (const tc of cases) {
            test(tc.name, async () => {
                const pcm = readPcm(tc.wav);
                const output = await streamPcmFast(server.port, pcm);
                expect(output.length).toBeGreaterThan(0);

                const refText = tc.ref ? await file(tc.ref).text() : null;
                const result = assertTranscript(output, refText, tc.thresholds, tc.name);
                results.push(result);
                if (result.error) throw result.error;
            }, timeoutMs);
        }
    });
}

runGroup("short", shortCases, runShort, [], 120_000);
runGroup("medium", mediumCases, runMedium, [], 180_000);
runGroup("long", longCases, runLong, ["--domain-terms", "test/dictation-terms.txt"], 300_000);

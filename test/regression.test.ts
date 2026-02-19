import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { file } from "bun";
import {
    hasGpu, ensureBinary, ensureFile, wavDuration,
    startServer, readPcm, streamPcmFast, assertTranscript,
    wordDiff, saveLog, type Thresholds,
} from "./helpers";

const gpu = await hasGpu();

interface TestCase {
    name: string;
    wav: string;
    ref: string | null;
    thresholds?: Thresholds;
}

const shortCases: TestCase[] = [
    { name: "jfk", wav: "test/jfk.wav", ref: "test/jfk.txt" },
    { name: "fully-committed", wav: "test/fully-committed.wav", ref: "test/fully-committed.txt" },
    { name: "working-test", wav: "test/working-test.wav", ref: "test/working-test.txt" },
    { name: "queued-fix", wav: "test/queued-fix.wav", ref: "test/queued-fix.txt" },
];

const mediumCases: TestCase[] = [
    { name: "long-pause", wav: "test/long-pause.wav", ref: "test/long-pause.txt", thresholds: { minCoverage: 75, maxGapSec: 4 } },
    { name: "repetition-loop", wav: "test/repetition-loop.wav", ref: "test/repetition-loop.txt", thresholds: { maxExtras: 30 } },
];

const longCases: TestCase[] = [
    { name: "dictation", wav: "test/dictation.wav", ref: "test/dictation.txt" },
    // Fast-forward overwhelms 30s buffer on 100+s files — phrase-level repetition during
    // streaming degrades quality. Track with loose thresholds, tighten as we improve.
    { name: "long-recording", wav: "test/long-recording.wav", ref: "test/long-recording.txt", thresholds: { minCoverage: 20, maxExtras: 400, maxMissed: 180 } },
    { name: "repetition-loop-long", wav: "test/repetition-loop-long.wav", ref: "test/repetition-loop-long.txt", thresholds: { minCoverage: 20, maxExtras: 500, maxMissed: 200 } },
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

        beforeAll(async () => {
            ensureBinary();
            for (const c of cases) {
                ensureFile(c.wav);
                if (c.ref) ensureFile(c.ref, "reference transcript");
            }
            server = await startServer(["--port", "0", "--verbose", ...serverArgs]);
        });

        afterAll(() => {
            if (server) {
                saveLog(server.logFile, groupName);
                server.kill();
            }
        });

        for (const tc of cases) {
            test(tc.name, async () => {
                const duration = wavDuration(tc.wav);
                console.error(`\nStreaming ${tc.wav} (${duration}s) to localhost:${server.port}...`);

                const pcm = readPcm(tc.wav);
                const output = await streamPcmFast(server.port, pcm);
                expect(output.length).toBeGreaterThan(0);

                const refText = tc.ref ? await file(tc.ref).text() : null;
                const result = assertTranscript(output, refText, tc.thresholds, tc.name);

                if (refText) {
                    await wordDiff(result.streamText, refText);
                }
            }, timeoutMs);
        }
    });
}

runGroup("short", shortCases, runShort, [], 120_000);
runGroup("medium", mediumCases, runMedium, [], 180_000);
runGroup("long", longCases, runLong, ["--domain-terms", "test/dictation-terms.txt"], 300_000);

import { describe, test, expect, afterAll } from "bun:test";
import { file } from "bun";
import {
    hasGpu, ensureBinary, ensureFile,
    startServer, readPcm, streamPcmFast,
    normalize, saveLog,
} from "./helpers";

const gpu = await hasGpu();

const dropTerms = process.env.DROP_TERMS ?? "test/drop-terms-nemotron.txt";
const extraServerArgs: string[] = [
    ...(process.env.ASR_MODEL ? ["--model", process.env.ASR_MODEL] : []),
    "--drop-terms", dropTerms,
];

describe.skipIf(!gpu)("concurrent TCP", () => {
    let server: Awaited<ReturnType<typeof startServer>> | null = null;

    afterAll(() => {
        if (server) {
            saveLog(server.logFile, "concurrent-tcp");
            server.kill();
        }
    });

    test("two simultaneous streams produce independent transcriptions", async () => {
        ensureBinary();
        ensureFile("test/jfk.wav");
        ensureFile("test/fully-committed.wav");
        ensureFile("test/jfk.txt", "reference transcript");
        ensureFile("test/fully-committed.txt", "reference transcript");

        server = await startServer(["--port", "0", "--verbose", ...extraServerArgs]);

        const pcmJfk = readPcm("test/jfk.wav");
        const pcmFc = readPcm("test/fully-committed.wav");

        // Stream both files simultaneously to the same server
        const [outputJfk, outputFc] = await Promise.all([
            streamPcmFast(server.port, pcmJfk),
            streamPcmFast(server.port, pcmFc),
        ]);

        const refJfk = normalize(await file("test/jfk.txt").text());
        const refFc = normalize(await file("test/fully-committed.txt").text());

        const normJfk = normalize(outputJfk);
        const normFc = normalize(outputFc);

        console.error(`\n=== Concurrent TCP ===`);
        console.error(`  JFK output:    "${normJfk}"`);
        console.error(`  JFK ref:       "${refJfk}"`);
        console.error(`  FC output:     "${normFc}"`);
        console.error(`  FC ref:        "${refFc}"`);

        // Each output should contain words from its own reference
        const jfkWords = refJfk.split(" ");
        const fcWords = refFc.split(" ");

        // JFK output should contain most JFK words
        const jfkHits = jfkWords.filter(w => normJfk.includes(w)).length;
        const jfkCoverage = jfkHits / jfkWords.length * 100;
        console.error(`  JFK coverage:  ${jfkCoverage.toFixed(0)}% (${jfkHits}/${jfkWords.length})`);
        expect(jfkCoverage).toBeGreaterThanOrEqual(80);

        // FC output should contain most FC words
        const fcHits = fcWords.filter(w => normFc.includes(w)).length;
        const fcCoverage = fcHits / fcWords.length * 100;
        console.error(`  FC coverage:   ${fcCoverage.toFixed(0)}% (${fcHits}/${fcWords.length})`);
        expect(fcCoverage).toBeGreaterThanOrEqual(80);

        // Cross-talk check: JFK output should NOT contain distinctive FC words
        // and vice versa. Use words unique to each reference.
        const jfkOnly = jfkWords.filter(w => !fcWords.includes(w) && w.length > 3);
        const fcOnly = fcWords.filter(w => !jfkWords.includes(w) && w.length > 3);

        const jfkInFc = jfkOnly.filter(w => normFc.includes(w));
        const fcInJfk = fcOnly.filter(w => normJfk.includes(w));

        if (jfkInFc.length > 0) console.error(`  CROSS-TALK: JFK words in FC output: ${jfkInFc.join(", ")}`);
        if (fcInJfk.length > 0) console.error(`  CROSS-TALK: FC words in JFK output: ${fcInJfk.join(", ")}`);

        expect(jfkInFc.length).toBe(0);
        expect(fcInJfk.length).toBe(0);
    }, 120_000);
});

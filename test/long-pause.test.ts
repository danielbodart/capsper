import { describe, test, expect, beforeAll } from "bun:test";
import { file } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, startServer, readPcm, streamPcm, normalize, compareWords } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("long-pause regression", () => {
    beforeAll(() => ensureBinary());

    test("no long emission gaps at 15s buffer boundary", async () => {
        const wav = "test/long-pause.wav";
        const ref = "test/long-pause.txt";
        ensureFile(wav);
        ensureFile(ref, "reference transcript");

        const duration = wavDuration(wav);
        console.error(`Audio: ${wav} (${duration}s)`);

        const server = await startServer(["--port", "0", "--verbose"]);
        try {
            const pcm = readPcm(wav);
            const output = await streamPcm(server.port, pcm);
            expect(output.length).toBeGreaterThan(0);

            // Parse emission timeline: "timestamp\ttext\n"
            const lines = output.split("\n").filter(Boolean);
            const emissions = lines.map(line => {
                const [ts, ...rest] = line.split("\t");
                return { time: parseFloat(ts), text: rest.join("\t") };
            });

            console.error("");
            console.error("=== Emission Timeline ===");
            for (const e of emissions) {
                console.error(`  ${e.time.toFixed(1)}s  ${e.text}`);
            }

            // Check maximum gap between consecutive emissions.
            // Before the fix, the gap at the 15s boundary was ~15s in real-time.
            // With the fix, it should be at most ~2s (natural speech pause + 1-2 cycles).
            let maxGap = 0;
            let maxGapAfter = "";
            for (let i = 1; i < emissions.length; i++) {
                const gap = emissions[i].time - emissions[i - 1].time;
                if (gap > maxGap) {
                    maxGap = gap;
                    maxGapAfter = emissions[i].text.trim();
                }
            }

            console.error("");
            console.error(`Max emission gap: ${maxGap.toFixed(1)}s (before "${maxGapAfter.slice(0, 40)}")`);

            // The gap must be under 4s. Before the fix it was 4.7s+ in replay, 15s+ in real-time.
            // Natural speech pauses + cycle overhead at 15s boundary = ~2.5-3s is expected.
            expect(maxGap).toBeLessThan(4.0);

            // Also verify word coverage
            const streamText = emissions.map(e => e.text).join(" ").replace(/\s+/g, " ").trim();
            const refText = await file(ref).text();
            const streamWords = normalize(streamText).split(" ").filter(Boolean);
            const refWords = normalize(refText).split(" ").filter(Boolean);
            const result = compareWords(streamWords, refWords);

            console.error(`Coverage: ${result.coverage}% (${result.matched}/${result.total})`);
            expect(parseFloat(result.coverage)).toBeGreaterThanOrEqual(75);
        } finally {
            server.kill();
        }
    }, 120_000);
});

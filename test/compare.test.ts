import { describe, test, expect, beforeAll } from "bun:test";
import { $, file } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, tmpFile, startServer, normalize, compareWords } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("compare", () => {
    beforeAll(() => ensureBinary());

    test("streaming output matches reference transcript", async () => {
        const name = process.env.TEST_NAME ?? "long-recording";
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

            const coveragePct = parseFloat(result.coverage);
            expect(result.matched).toBeGreaterThan(0);
            expect(coveragePct).toBeGreaterThanOrEqual(50);
        } finally {
            server.kill();
            await $`rm -f ${streamOutput}`.nothrow();
        }
    }, 240_000);
});

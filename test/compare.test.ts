import { describe, test, expect, beforeAll } from "bun:test";
import { spawn, file } from "bun";
import { $ } from "bun";
import { existsSync } from "fs";
import { hasGpu, ensureBinary, ensureFile, wavDuration, waitForLog, startLocalServer, normalize, compareWords, trackProc } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("compare", () => {
    beforeAll(() => ensureBinary());

    test("streaming output matches reference transcript", async () => {
        const name = process.env.TEST_NAME ?? "long-recording";
        const wav = `test/${name}.wav`;
        const ref = `test/${name}.txt`;
        ensureFile(wav);
        ensureFile(ref, "reference transcript");

        const duration = wavDuration(wav);

        const LOOPBACK_SINK = "test-compare-loopback-sink";
        const LOOPBACK_SOURCE = "test-compare-loopback-source";

        // Start pw-loopback: creates a virtual sink/source pair
        const loopback = spawn([
            "pw-loopback",
            `--capture-props=media.class=Audio/Sink node.name=${LOOPBACK_SINK}`,
            `--playback-props=media.class=Audio/Source node.name=${LOOPBACK_SOURCE}`,
            "-C", "1", "-m", "MONO",
        ], { stdout: "ignore", stderr: "ignore" });
        trackProc(loopback);

        await Bun.sleep(1000);

        try {
            // Verify loopback created the source node
            const { exitCode: linkCheck } = await $`pw-link -o 2>/dev/null | grep -q ${LOOPBACK_SOURCE}`.quiet().nothrow();
            expect(linkCheck).toBe(0); // PipeWire loopback must be available

            const serverArgs = [
                "--input", "local",
                "--pw-target", LOOPBACK_SOURCE,
                "--pw-channel", "MONO",
                "--verbose",
            ];

            const termsFile = `test/${name}-terms.txt`;
            if (existsSync(termsFile)) {
                serverArgs.push("--domain-terms", termsFile);
                console.error(`Domain terms: ${termsFile}`);
            }

            const server = await startLocalServer(serverArgs);

            try {
                console.error("=== Streaming Comparison Test (PipeWire) ===");
                console.error(`Audio: ${wav} (${duration}s)`);
                console.error(`Reference: ${ref}`);
                console.error("");
                console.error("Playing via PipeWire loopback...");

                // Play WAV through the loopback sink (pw-cat handles real-time pacing)
                const pwcat = spawn([
                    "pw-cat", "-p",
                    `--target=${LOOPBACK_SINK}`,
                    "--rate=16000", "--channels=1", "--format=s16",
                    wav,
                ], { stdout: "ignore", stderr: "ignore" });
                trackProc(pwcat);

                await pwcat.exited;

                // Wait for server to flush trailing transcription
                await waitForLog(server.logFile, /flush → idle/, server.proc, 30);

                const rawOutput = await file(server.outputFile).text();

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
                const extras = streamWords.length - result.matched;

                console.error("");
                console.error("=== Results ===");
                console.error(`Matched: ${result.matched} / ${result.total} words (${result.coverage}%)`);
                console.error(`Missed:  ${result.missed.length} words`);
                console.error(`Extras:  ${extras} words (duplicates/hallucinations)`);

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
                console.error(`Coverage: ${result.coverage}% (${result.matched}/${result.total}), extras: ${extras}`);
                console.error(`Duration: ${duration}s`);

                // Machine-readable summary to stdout
                console.log(`${result.matched}/${result.total} ${result.coverage}% extras:${extras}`);

                const coveragePct = parseFloat(result.coverage);
                expect(result.matched).toBeGreaterThan(0);
                expect(coveragePct).toBeGreaterThanOrEqual(85);
                expect(extras).toBeLessThanOrEqual(15);  // minor model word-choice differences (e.g. "five" vs "5")
                expect(result.missed.length).toBeLessThanOrEqual(25);  // some words may not match due to model variability
            } finally {
                server.kill();
            }
        } finally {
            loopback.kill();
        }
    }, 240_000);
});

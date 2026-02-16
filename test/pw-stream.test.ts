import { describe, test, expect, beforeAll } from "bun:test";
import { $, spawn, file } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, waitForLog, startLocalServer, trackProc } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("pw-stream", () => {
    beforeAll(() => ensureBinary());

    test("streams wav file via PipeWire loopback", async () => {
        const wavFile = process.env.TEST_WAV ?? "test/jfk.wav";
        ensureFile(wavFile);
        const duration = wavDuration(wavFile);

        const LOOPBACK_SINK = "test-whisper-loopback-sink";
        const LOOPBACK_SOURCE = "test-whisper-loopback-source";

        // Start pw-loopback: creates a virtual sink + source bridge
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

            const server = await startLocalServer([
                "--input", "local",
                "--pw-target", LOOPBACK_SOURCE,
                "--pw-channel", "MONO",
                "--verbose",
            ]);

            try {
                console.error(`Streaming ${wavFile} (${duration}s) via PipeWire...`);

                // Play WAV through the loopback sink (pw-cat handles real-time pacing)
                const pwcat = spawn([
                    "pw-cat", "-p",
                    `--target=${LOOPBACK_SINK}`,
                    "--rate=16000", "--channels=1", "--format=s16",
                    wavFile,
                ], { stdout: "ignore", stderr: "ignore" });
                trackProc(pwcat);

                await pwcat.exited;

                // Wait for server to flush trailing transcription (2s silence timeout + transcribe)
                await waitForLog(server.logFile, /flush → idle/, server.proc, 10);

                const output = await file(server.outputFile).text();
                console.error("");
                console.error("=== Streaming Output ===");
                console.error(output);

                const wordCount = output.split("\n").filter(Boolean)
                    .map(line => line.split("\t").slice(1).join("\t"))
                    .join(" ").split(/\s+/).filter(Boolean).length;
                console.error(`\nTotal words emitted: ${wordCount}`);

                expect(wordCount).toBeGreaterThan(0);
            } finally {
                server.kill();
            }
        } finally {
            loopback.kill();
        }
    }, 120_000);
});

import { describe, test, expect, beforeAll } from "bun:test";
import { $, spawn, file } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, waitForLog, startLocalServer, trackProc, saveLog } from "./helpers";

const isLinux = process.platform === "linux";

describe.skipIf(!isLinux)("pw-stream", () => {
    beforeAll(() => ensureBinary());

    test("streams wav file via PipeWire loopback", async () => {
        const wavFile = process.env.TEST_WAV ?? "test/jfk.wav";
        ensureFile(wavFile);
        const duration = wavDuration(wavFile);

        const LOOPBACK_SINK = "test-capsper-loopback-sink";
        const LOOPBACK_SOURCE = "test-capsper-loopback-source";

        // Start pw-loopback: creates a virtual sink + source bridge.
        // audio.rate=16000 prevents double resampling through the 48kHz graph.
        const loopback = spawn([
            "pw-loopback",
            `--capture-props={"media.class":"Audio/Sink", "node.name":"${LOOPBACK_SINK}", "audio.rate":16000}`,
            `--playback-props={"media.class":"Audio/Source", "node.name":"${LOOPBACK_SOURCE}", "audio.rate":16000}`,
            "-C", "1", "-m", "MONO",
        ], { stdout: "ignore", stderr: "ignore" });
        trackProc(loopback);

        await Bun.sleep(1000);

        try {
            // Verify loopback created the source node
            const { exitCode: linkCheck } = await $`pw-link -o 2>/dev/null | grep -q ${LOOPBACK_SOURCE}`.quiet().nothrow();
            expect(linkCheck).toBe(0); // PipeWire loopback must be available

            const server = await startLocalServer([
                "--audio-target", LOOPBACK_SOURCE,
                "--audio-channel", "MONO",
                "--on-device-lost", "exit",
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

                // Kill the loopback → PipeWire destroys the source node →
                // hotplug monitor detects target removal → closes audio pipe →
                // server's ChunkedReader gets EOF → clean exit.
                try { loopback.kill(); } catch {}
                await Bun.sleep(500); // let PipeWire propagate node destruction

                await waitForLog(server.logFile, /session ended/, server.proc, 10);

                const output = await file(server.outputFile).text();
                console.error("");
                console.error("=== Streaming Output ===");
                console.error(output);

                const wordCount = output.split(/\s+/).filter(Boolean).length;
                console.error(`\nTotal words emitted: ${wordCount}`);

                expect(wordCount).toBeGreaterThan(0);
            } finally {
                saveLog(server.logFile, "pw-stream");
                server.kill();
            }
        } finally {
            try { loopback.kill(); } catch {}
        }
    }, 120_000);
});

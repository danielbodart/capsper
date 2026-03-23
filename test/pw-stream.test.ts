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

                // Kill the loopback → PipeWire destroys the source node →
                // server's PW stream gets ERROR state → onStateChanged closes pipe →
                // server's read() returns EOF → flush → idle
                try { loopback.kill(); } catch {}
                await Bun.sleep(200); // let PipeWire propagate node destruction

                await waitForLog(server.logFile, /flush → idle/, server.proc, 30);

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
                saveLog(server.logFile, "pw-stream");
                server.kill();
            }
        } finally {
            try { loopback.kill(); } catch {}
        }
    }, 120_000);
});

import { describe, test, expect, beforeAll } from "bun:test";
import { $, spawn, file } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, waitForLog, startLocalServer, trackProc, saveLog } from "./helpers";

const gpu = await hasGpu();
const isMacOS = process.platform === "darwin";

// Check if BlackHole virtual audio device is available
async function hasBlackHole(): Promise<boolean> {
    if (!isMacOS) return false;
    const { exitCode } = await $`system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"`.quiet().nothrow();
    return exitCode === 0;
}

const blackhole = await hasBlackHole();

describe.skipIf(!gpu || !blackhole)("ca-stream", () => {
    beforeAll(() => ensureBinary());

    test("streams wav file via BlackHole loopback", async () => {
        const wavFile = process.env.TEST_WAV ?? "test/jfk.wav";
        ensureFile(wavFile);
        const duration = wavDuration(wavFile);

        const server = await startLocalServer([
            "--input", "local",
            "--pw-target", "BlackHole 2ch",
            "--pw-channel", "MONO",
            "--no-auto-gain",
            "--verbose",
        ]);

        try {
            console.error(`Streaming ${wavFile} (${duration}s) via BlackHole...`);

            // Play WAV through BlackHole using sox (real-time pacing)
            const soxPlay = spawn(["play", wavFile], {
                stdout: "ignore",
                stderr: "ignore",
                env: { ...process.env, AUDIODEV: "BlackHole 2ch" },
            });
            trackProc(soxPlay);

            await soxPlay.exited;

            // Give the pipeline time to flush after audio ends
            await Bun.sleep(3000);

            // Send SIGTERM to trigger clean shutdown + final flush
            server.kill();
            await Bun.sleep(1000);

            const output = await file(server.outputFile).text();
            const log = await file(server.logFile).text();
            console.error("");
            console.error("=== Streaming Output ===");
            console.error(output);

            // Check for VAD transitions in the log
            const speakingCount = (log.match(/idle → speaking/g) || []).length;
            console.error(`\nVAD speaking segments: ${speakingCount}`);

            const wordCount = output.split("\n").filter(Boolean)
                .map(line => line.split("\t").slice(1).join("\t"))
                .join(" ").split(/\s+/).filter(Boolean).length;
            console.error(`Total words emitted: ${wordCount}`);

            expect(wordCount).toBeGreaterThan(0);
        } finally {
            saveLog(server.logFile, "ca-stream");
            server.kill();
        }
    }, 120_000);
});

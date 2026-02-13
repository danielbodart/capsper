import { describe, test, expect, beforeAll } from "bun:test";
import { $ } from "bun";
import { statSync } from "fs";
import { hasGpu, ensureBinary, ensureFile, tmpFile, startServer } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("long-stream", () => {
    beforeAll(() => {
        ensureBinary();
        ensureFile("jfk.wav");
    });

    test("streams 20 loops of jfk.wav without crashing", async () => {
        const LOOPS = 20;
        const rawPcm = tmpFile("whisper-test", ".raw");

        // Extract raw PCM (skip 44-byte WAV header)
        await $`tail -c +45 jfk.wav > ${rawPcm}`;
        const rawSize = statSync(rawPcm).size;
        const durationPerLoop = (rawSize / 32000).toFixed(1);
        const totalDuration = (rawSize * LOOPS / 32000).toFixed(1);

        const server = await startServer(["--port", "0", "--verbose"]);

        try {
            console.error(`Raw PCM: ${rawSize} bytes per loop (${durationPerLoop}s)`);
            console.error(`Streaming ${LOOPS} loops = ${totalDuration}s to localhost:${server.port}`);
            console.error("---");

            // Concatenate N loops of raw PCM, pipe at real-time rate
            const loopCmd = Array.from({ length: LOOPS }, () => `cat ${rawPcm}`).join("; ");
            await $`bash -c ${`(${loopCmd}) | pv -qL 32000 | nc -q 5 localhost ${server.port}`}`;

            console.error("---");
            console.error("Done.");

            // Server should still be alive (not crashed)
            expect(server.proc.exitCode).toBeNull();
        } finally {
            server.kill();
            await $`rm -f ${rawPcm}`.nothrow();
        }
    }, 300_000);
});

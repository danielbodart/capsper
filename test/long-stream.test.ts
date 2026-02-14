import { describe, test, expect, beforeAll } from "bun:test";
import { hasGpu, ensureBinary, ensureFile, startServer, readPcm, streamPcm } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("long-stream", () => {
    beforeAll(() => {
        ensureBinary();
        ensureFile("test/jfk.wav");
    });

    test("streams 20 loops of jfk.wav without crashing", async () => {
        const LOOPS = 20;
        const pcmOnce = readPcm("test/jfk.wav");
        const pcm = Buffer.concat(Array.from({ length: LOOPS }, () => pcmOnce));
        const totalDuration = (pcm.length / 32000).toFixed(1);

        const server = await startServer(["--port", "0", "--verbose"]);

        try {
            console.error(`Streaming ${LOOPS} loops = ${totalDuration}s to localhost:${server.port}`);
            console.error("---");

            await streamPcm(server.port, pcm);

            console.error("---");
            console.error("Done.");

            // Server should still be alive (not crashed)
            expect(server.proc.exitCode).toBeNull();
        } finally {
            server.kill();
        }
    }, 300_000);
});

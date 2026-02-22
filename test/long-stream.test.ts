import { describe, test, expect, beforeAll } from "bun:test";
import { hasGpu, ensureBinary, ensureFile, startServer, readPcm, streamPcmFast, saveLog } from "./helpers";

const gpu = await hasGpu();
const vadBackend = process.env.VAD_BACKEND;
const extraServerArgs: string[] = vadBackend ? ["--vad", vadBackend] : [];

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

        const server = await startServer(["--port", "0", "--verbose", ...extraServerArgs]);

        try {
            console.error(`Streaming ${LOOPS} loops = ${totalDuration}s to localhost:${server.port}`);
            console.error("---");

            await streamPcmFast(server.port, pcm);

            console.error("---");
            console.error("Done.");

            // Server should still be alive (not crashed)
            expect(server.proc.exitCode).toBeNull();
        } finally {
            saveLog(server.logFile, "long-stream");
            server.kill();
        }
    }, 300_000);
});

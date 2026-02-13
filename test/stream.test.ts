import { describe, test, expect, beforeAll } from "bun:test";
import { hasGpu, ensureBinary, ensureFile, wavDuration, startServer, readPcm, streamPcm } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("stream", () => {
    beforeAll(() => ensureBinary());

    test("streams wav file via TCP at real-time rate", async () => {
        const wavFile = process.env.TEST_WAV ?? "jfk.wav";
        ensureFile(wavFile);
        const duration = wavDuration(wavFile);

        const server = await startServer(["--port", "0", "--verbose"]);
        try {
            console.error(`Streaming ${wavFile} (${duration}s) to localhost:${server.port}...`);
            const pcm = readPcm(wavFile);
            const output = await streamPcm(server.port, pcm);
            console.error(`Output (${output.length} bytes): ${output.slice(0, 500)}`);
            expect(output.length).toBeGreaterThan(0);
        } finally {
            server.kill();
        }
    }, 120_000);
});

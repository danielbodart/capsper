import { describe, test, expect, beforeAll } from "bun:test";
import { $ } from "bun";
import { hasGpu, ensureBinary, ensureFile, wavDuration, startServer } from "./helpers";

const gpu = await hasGpu();

describe.skipIf(!gpu)("stream", () => {
    beforeAll(() => ensureBinary());

    test("streams wav file via TCP at real-time rate", async () => {
        const wavFile = process.env.TEST_WAV ?? "jfk.wav";
        ensureFile(wavFile);
        const duration = wavDuration(wavFile);
        const timeoutMs = (parseFloat(duration) + 30) * 1000;

        const server = await startServer(["--port", "0", "--verbose"]);
        try {
            console.error(`Streaming ${wavFile} (${duration}s, timeout ${(timeoutMs / 1000).toFixed(0)}s) to localhost:${server.port}...`);
            const result = await Promise.race([
                $`tail -c +45 ${wavFile} | pv -qL 32000 | nc -q 5 localhost ${server.port}`.quiet().nothrow(),
                Bun.sleep(timeoutMs).then(() => { throw new Error(`Test timed out after ${timeoutMs / 1000}s`); }),
            ]);
            const output = result.text();
            console.error(`Output (${output.length} bytes): ${output.slice(0, 500)}`);
            expect(output.length).toBeGreaterThan(0);
        } finally {
            server.kill();
        }
    }, 120_000);
});

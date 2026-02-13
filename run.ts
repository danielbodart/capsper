#!/usr/bin/env ./bootstrap.sh
import { $, spawn, file } from "bun";
import { existsSync, statSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

process.env.FORCE_COLOR = "1";

const BINARY = "./zig-out/bin/whisper-dictate";
const MODEL = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
const VAD_MODEL = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

function tmpFile(prefix: string, ext: string): string {
    return join(tmpdir(), `${prefix}-${Date.now()}${ext}`);
}

/** Wait for a pattern to appear in a log file, or throw on timeout / process death. */
async function waitForLog(logFile: string, pattern: RegExp, proc: ReturnType<typeof spawn>, timeoutSec = 60): Promise<string> {
    const deadline = Date.now() + timeoutSec * 1000;
    while (Date.now() < deadline) {
        if (proc.exitCode !== null) {
            const log = await file(logFile).text().catch(() => "(empty)");
            throw new Error(`Server died during startup. Log:\n${log}`);
        }
        const text = await file(logFile).text().catch(() => "");
        const match = text.match(pattern);
        if (match) return match[0];
        await Bun.sleep(500);
    }
    const log = await file(logFile).text().catch(() => "(empty)");
    throw new Error(`Timed out waiting for ${pattern} after ${timeoutSec}s. Log:\n${log.slice(-2000)}`);
}

/** Start the whisper-dictate server with given args, wait for ready, return handle. */
async function startServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; port: number; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");

    const proc = spawn([BINARY, ...args], {
        stdout: Bun.file(logFile),
        stderr: Bun.file(logFile),
    });

    const kill = () => {
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        const line = await waitForLog(logFile, /Listening on port (\d+)/, proc);
        const port = parseInt(line.match(/\d+/)![0]);
        console.error(`Server ready on port ${port} (PID ${proc.pid})`);
        return { proc, port, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

/** Start the server in local PipeWire capture mode, wait for "Capturing audio". */
async function startLocalServer(args: string[]): Promise<{ proc: ReturnType<typeof spawn>; outputFile: string; logFile: string; kill: () => void }> {
    const logFile = tmpFile("whisper-server", ".log");
    const outputFile = tmpFile("whisper-pw-stream", ".txt");

    const proc = spawn([BINARY, ...args], {
        stdout: Bun.file(outputFile),
        stderr: Bun.file(logFile),
    });

    const kill = () => {
        proc.kill();
        try { proc.kill(9); } catch {}
    };

    try {
        await waitForLog(logFile, /Capturing audio/, proc);
        console.error(`Server capturing audio (PID ${proc.pid})`);
        return { proc, outputFile, logFile, kill };
    } catch (e) {
        kill();
        throw e;
    }
}

// ─── Text comparison (from test-compare.sh) ────────────────────────────────

function normalize(text: string): string {
    return text.toLowerCase().replace(/[^a-z0-9' ]/g, " ").replace(/\s+/g, " ").trim();
}

function compareWords(streamWords: string[], refWords: string[]): { matched: number; total: number; coverage: string; missed: string[] } {
    let matched = 0;
    let streamIdx = 0;
    const missed: string[] = [];

    for (let r = 0; r < refWords.length; r++) {
        let found = false;
        for (let look = 0; look < 5 && streamIdx + look < streamWords.length; look++) {
            if (refWords[r] === streamWords[streamIdx + look]) {
                matched++;
                streamIdx = streamIdx + look + 1;
                found = true;
                break;
            }
        }
        if (!found) missed.push(refWords[r]);
    }

    const total = refWords.length;
    const coverage = total > 0 ? (matched * 100 / total).toFixed(1) : "0";
    return { matched, total, coverage, missed };
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps() {
    const missing: string[] = [];

    // Core build deps
    if (!await which("cmake")) missing.push("cmake");
    if (!await which("pkg-config")) missing.push("pkg-config");

    // PipeWire dev headers
    const { exitCode: pwCheck } = await $`pkg-config --exists libpipewire-0.3`.quiet().nothrow();
    if (pwCheck !== 0) missing.push("libpipewire-0.3-dev");

    // CUDA
    if (!await which("nvidia-smi")) {
        console.error("WARNING: nvidia-smi not found. CUDA may not be available.");
    }
    if (!await which("nvcc")) missing.push("nvidia-cuda-toolkit");

    // Streaming test deps
    if (!await which("pv")) missing.push("pv");
    if (!await which("nc") && !await which("ncat")) missing.push("ncat");

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

async function ensureSubmodule() {
    // Check if whisper.cpp is populated
    if (!existsSync("whisper.cpp/CMakeLists.txt")) {
        console.log("Initializing whisper.cpp submodule...");
        await $`git submodule update --init --recursive`;
    }
}

async function confirm(message: string): Promise<boolean> {
    process.stdout.write(`${message} [Y/n] `);
    return new Promise<boolean>(resolve => {
        const onData = (chunk: Buffer) => {
            process.stdin.removeListener("data", onData);
            process.stdin.pause();
            const answer = chunk.toString().trim().toLowerCase();
            resolve(answer === "" || answer === "y" || answer === "yes");
        };
        process.stdin.resume();
        process.stdin.on("data", onData);
    });
}

async function ensureModels() {
    const missing: string[] = [];
    if (!existsSync(MODEL)) missing.push(`Whisper model (large-v3-turbo-q5_0, ~574 MB)`);
    if (!existsSync(VAD_MODEL)) missing.push(`VAD model (silero-v5.1.2, ~2 MB)`);

    if (missing.length === 0) return;

    console.log(`Missing models:\n${missing.map(m => `  - ${m}`).join("\n")}`);
    if (!await confirm("Download now?")) {
        console.error("Models required. Download manually:");
        console.error("  cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0");
        console.error("  cd whisper.cpp/models && ./download-vad-model.sh silero-v5.1.2");
        process.exit(1);
    }

    if (!existsSync(MODEL)) {
        console.log("Downloading Whisper model...");
        await $`cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0`;
    }
    if (!existsSync(VAD_MODEL)) {
        console.log("Downloading VAD model...");
        await $`cd whisper.cpp/models && ./download-vad-model.sh silero-v5.1.2`;
    }
}

function ensureBinary() {
    if (!existsSync(BINARY)) {
        console.error(`Binary not found: ${BINARY}`);
        console.error("Run: ./run");
        process.exit(1);
    }
}

function ensureFile(path: string, label?: string) {
    if (!existsSync(path)) {
        console.error(`File not found: ${path}${label ? ` (${label})` : ""}`);
        process.exit(1);
    }
}

/** Write content to path only if it differs from existing file. Returns true if written. */
async function writeIfChanged(path: string, content: string): Promise<boolean> {
    const existing = await file(path).text().catch(() => "");
    if (existing === content) return false;
    await Bun.write(path, content);
    return true;
}

function wavDuration(path: string): string {
    const rawSize = statSync(path).size - 44;
    return (rawSize / 32000).toFixed(1);
}

type PwDetectResult = { channel: string; target?: string };

// ─── Commands ──────────────────────────────────────────────────────────────

export async function build() {
    await ensureDeps();
    await ensureSubmodule();
    await ensureModels();
    console.log("Building...");
    await $`zig build`;
}

export async function rebuild() {
    await ensureDeps();
    await ensureSubmodule();
    await ensureModels();
    console.log("Rebuilding (forcing CMake + CUDA recompilation)...");
    await $`zig build -Dforce-cmake`;
}

export async function clean() {
    await $`rm -rf zig-out .zig-cache whisper.cpp/build-zig`;
    console.log("Cleaned.");
}

async function updateServiceFile(pw: PwDetectResult) {
    const home = process.env.HOME!;
    const serviceDir = `${home}/.config/systemd/user`;
    await $`mkdir -p ${serviceDir}`;

    const envLines = [`Environment=PATH=${home}/.local/bin:/usr/local/bin:/usr/bin:/bin`];

    // evdev mode: binary handles everything directly, no display server dependency
    let execStart = `${SCRIPT_DIR}/zig-out/bin/whisper-dictate --trigger capslock --pw-channel ${pw.channel}`;
    if (pw.target) {
        execStart += ` --pw-target ${pw.target}`;
    }

    const serviceContent = `[Unit]
Description=Whisper push-to-talk dictation

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${execStart}
Restart=always
RestartSec=5
${envLines.join("\n")}

[Install]
WantedBy=default.target
`;

    const servicePath = `${serviceDir}/whisper.service`;
    if (await writeIfChanged(servicePath, serviceContent)) {
        await $`systemctl --user daemon-reload`;
        console.log("whisper.service updated");
    }
    await $`systemctl --user enable whisper.service`.quiet().nothrow();
}

export async function setup() {
    await build();

    // Ensure user is in 'input' group for evdev/uinput access
    const { exitCode: inInputGroup } = await $`id -nG | grep -qw input`.quiet().nothrow();
    if (inInputGroup !== 0) {
        console.log("\n=== Permissions Setup ===");
        console.log("The 'input' group is needed for keyboard grab and text injection.");
        if (await confirm("Add current user to 'input' group? (requires sudo)")) {
            await $`sudo usermod -aG input ${process.env.USER}`;
            console.log("Added to 'input' group. You may need to log out and back in.");
        }
    }

    // Ensure uinput device is accessible
    const uinputRule = '/etc/udev/rules.d/99-uinput.rules';
    const { exitCode: uinputExists } = await $`test -f ${uinputRule}`.quiet().nothrow();
    if (uinputExists !== 0) {
        console.log("\nSetting up /dev/uinput access...");
        if (await confirm("Install udev rule for /dev/uinput? (requires sudo)")) {
            await $`echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee ${uinputRule}`;
            await $`sudo udevadm control --reload-rules && sudo udevadm trigger /dev/uinput`.nothrow();
            console.log("udev rule installed.");
        }
    }

    // Audio configuration — optionally run pwDetect to find the best mic channel
    let pwResult: PwDetectResult = { channel: "FL" };

    console.log("\n=== Audio Configuration ===");
    if (await confirm("Run microphone channel detection? (No = use default FL)")) {
        let audioConfigured = false;
        while (!audioConfigured) {
            try {
                pwResult = await pwDetect();
                audioConfigured = true;
            } catch (e: any) {
                console.error(`\nAudio detection failed: ${e.message}`);
                if (await confirm("Skip and use default channel FL?")) {
                    audioConfigured = true;
                } else if (!await confirm("Retry?")) {
                    process.exit(1);
                }
            }
        }
    } else {
        console.log("Using default channel: FL");
    }

    await updateServiceFile(pwResult);
    console.log("\nwhisper.service ready");

    if (await confirm("Start the dictation service now?")) {
        await $`systemctl --user restart whisper.service`;
        console.log("Service started. Check status with:");
        console.log("  systemctl --user status whisper.service");
    } else {
        console.log("\nStart manually with:");
        console.log("  systemctl --user start whisper.service");
    }
}

export async function testStream(wavFile = "jfk.wav") {
    ensureBinary();
    ensureFile(wavFile);

    const duration = wavDuration(wavFile);
    const timeoutMs = (parseFloat(duration) + 30) * 1000; // audio duration + 30s for startup/flush

    const server = await startServer(["--port", "0", "--verbose"]);
    try {
        console.error(`Streaming ${wavFile} (${duration}s, timeout ${(timeoutMs / 1000).toFixed(0)}s) to localhost:${server.port}...`);
        // Skip 44-byte WAV header, send at 32000 bytes/sec (16kHz S16 mono)
        await Promise.race([
            $`tail -c +45 ${wavFile} | pv -qL 32000 | nc -q 5 localhost ${server.port}`.nothrow(),
            Bun.sleep(timeoutMs).then(() => { throw new Error(`Test timed out after ${timeoutMs / 1000}s`); }),
        ]);
    } finally {
        server.kill();
    }
}

export async function testPwStream(wavFile = "jfk.wav") {
    ensureBinary();
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

    await Bun.sleep(1000);

    // Verify loopback created the source node
    const { exitCode: linkCheck } = await $`pw-link -o 2>/dev/null | grep -q ${LOOPBACK_SOURCE}`.quiet().nothrow();
    if (linkCheck !== 0) {
        loopback.kill();
        console.error("Failed to create PipeWire loopback. Is PipeWire running?");
        process.exit(1);
    }

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

        // Wait for playback to finish
        await pwcat.exited;

        // Give the server time to flush trailing transcription
        await Bun.sleep(3000);

        // Show results
        const output = await file(server.outputFile).text();
        console.error("");
        console.error("=== Streaming Output ===");
        console.error(output);

        const wordCount = output.split("\n").filter(Boolean)
            .map(line => line.split("\t").slice(1).join("\t"))
            .join(" ").split(/\s+/).filter(Boolean).length;
        console.error(`\nTotal words emitted: ${wordCount}`);
    } finally {
        server.kill();
        loopback.kill();
    }
}

export async function testLongStream() {
    ensureBinary();
    ensureFile("jfk.wav");

    const rawPcm = tmpFile("whisper-test", ".raw");
    const LOOPS = 20;

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
    } finally {
        server.kill();
        await $`rm -f ${rawPcm}`.nothrow();
    }
}

export async function testCompare(name = "long-recording") {
    ensureBinary();
    const wav = `testdata/${name}.wav`;
    const ref = `testdata/${name}.txt`;
    ensureFile(wav);
    ensureFile(ref, "reference transcript");

    const duration = wavDuration(wav);
    const streamOutput = tmpFile("whisper-compare", ".txt");

    const server = await startServer(["--port", "0", "--verbose"]);

    try {
        console.error("=== Streaming Comparison Test ===");
        console.error(`Audio: ${wav} (${duration}s)`);
        console.error(`Reference: ${ref}`);
        console.error(`Server: localhost:${server.port}`);
        console.error("");
        console.error("Streaming at real-time rate...");

        await $`tail -c +45 ${wav} | pv -qL 32000 | nc -q 1 localhost ${server.port} > ${streamOutput}`;

        const rawOutput = await file(streamOutput).text();
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

        console.error("");
        console.error("=== Results ===");
        console.error(`Matched: ${result.matched} / ${result.total} words (${result.coverage}%)`);
        console.error(`Missed:  ${result.missed.length} words`);

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
        console.error(`Coverage: ${result.coverage}% (${result.matched}/${result.total})`);
        console.error(`Duration: ${duration}s`);

        // Machine-readable summary to stdout
        console.log(`${result.matched}/${result.total} ${result.coverage}%`);
    } finally {
        server.kill();
        await $`rm -f ${streamOutput}`.nothrow();
    }
}

export async function pwDetect(targetDevice?: string, durationArg?: string): Promise<PwDetectResult> {
    if (!await which("pw-record")) {
        console.error("ERROR: pw-record not found. Install PipeWire.");
        process.exit(1);
    }

    const RECORD_SECS = durationArg ? parseInt(durationArg, 10) : 5;
    if (isNaN(RECORD_SECS) || RECORD_SECS < 1) {
        console.error("ERROR: Duration must be a positive integer (seconds).");
        process.exit(1);
    }
    const SAMPLE_RATE = 48000;
    const FORMAT = "s32"; // pw-record default for multichannel devices

    // Step 1: Discover target device info
    const targetArgs = targetDevice ? ["--target", targetDevice] : [];
    console.log(targetDevice
        ? `Probing device: ${targetDevice}`
        : "Probing default audio source...");
    console.log(`Recording duration: ${RECORD_SECS}s per phase`);
    console.log("");

    // Wait for Enter keypress
    async function waitForEnter(prompt: string) {
        process.stdout.write(prompt);
        return new Promise<void>(resolve => {
            const onData = () => {
                process.stdin.removeListener("data", onData);
                process.stdin.pause();
                if (wasTTYRaw) process.stdin.setRawMode(false);
                resolve();
            };
            const wasTTYRaw = process.stdin.isTTY;
            if (wasTTYRaw) process.stdin.setRawMode(true);
            process.stdin.resume();
            process.stdin.on("data", onData);
        });
    }

    function startRecording(outFile: string) {
        const args = ["pw-record", `--rate=${SAMPLE_RATE}`, `--format=${FORMAT}`, ...targetArgs, outFile];
        return Bun.spawn(args, { stdout: "ignore", stderr: "ignore" });
    }

    async function stopRecording(proc: ReturnType<typeof Bun.spawn>) {
        proc.kill();
        await proc.exited;
    }

    // Step 2: Record silence baseline
    await waitForEnter("Press ENTER to start recording SILENCE (stay quiet)...");
    console.log(`Recording ${RECORD_SECS}s of silence...`);
    const silenceFile = tmpFile("pw-detect-silence", ".wav");
    const silenceProc = startRecording(silenceFile);
    await Bun.sleep(RECORD_SECS * 1000);
    await stopRecording(silenceProc);
    console.log("Done.\n");

    // Parse WAV to get channel count
    const silenceData = await file(silenceFile).arrayBuffer();
    const silenceView = new DataView(silenceData);

    if (silenceData.byteLength < 44) {
        console.error("ERROR: Recording too short. Is PipeWire running?");
        process.exit(1);
    }

    const numChannels = silenceView.getUint16(22, true);
    const bitsPerSample = silenceView.getUint16(34, true);
    const bytesPerSample = bitsPerSample / 8;

    // Find data chunk
    let dataOffset = 12;
    let dataSize = 0;
    while (dataOffset + 8 < silenceData.byteLength) {
        const chunkId = String.fromCharCode(
            silenceView.getUint8(dataOffset),
            silenceView.getUint8(dataOffset + 1),
            silenceView.getUint8(dataOffset + 2),
            silenceView.getUint8(dataOffset + 3),
        );
        const chunkSize = silenceView.getUint32(dataOffset + 4, true);
        dataOffset += 8;
        if (chunkId === "data") {
            dataSize = chunkSize;
            break;
        }
        dataOffset += chunkSize;
    }

    const samplesPerChannel = Math.floor(dataSize / (numChannels * bytesPerSample));

    console.log(`  Channels: ${numChannels}, Format: S${bitsPerSample}LE, Rate: ${SAMPLE_RATE}Hz`);
    console.log(`  Samples per channel: ${samplesPerChannel}`);
    console.log("");

    // Compute per-channel RMS
    function channelRms(view: DataView, offset: number, nChannels: number, nSamples: number, bps: number, channel: number): number {
        let sumSq = 0;
        const scale = bps === 4 ? 2147483648 : (bps === 2 ? 32768 : 128);
        for (let i = 0; i < nSamples; i++) {
            const byteOff = offset + (i * nChannels + channel) * bps;
            if (byteOff + bps > view.byteLength) break;
            let sample: number;
            if (bps === 4) sample = view.getInt32(byteOff, true);
            else if (bps === 2) sample = view.getInt16(byteOff, true);
            else sample = view.getInt8(byteOff);
            const norm = sample / scale;
            sumSq += norm * norm;
        }
        return Math.sqrt(sumSq / nSamples);
    }

    function rmsToDb(rms: number): number {
        return rms > 1e-10 ? 20 * Math.log10(rms) : -100;
    }

    const silenceRms: number[] = [];
    for (let ch = 0; ch < numChannels; ch++) {
        silenceRms.push(channelRms(silenceView, dataOffset, numChannels, samplesPerChannel, bytesPerSample, ch));
    }

    // Step 3: Record with speech
    await waitForEnter("Press ENTER to start recording SPEECH (talk normally)...");
    console.log(`Recording ${RECORD_SECS}s of speech...`);
    const speechFile = tmpFile("pw-detect-speech", ".wav");
    const speechProc = startRecording(speechFile);
    await Bun.sleep(RECORD_SECS * 1000);
    await stopRecording(speechProc);
    console.log("Done.\n");

    const speechData = await file(speechFile).arrayBuffer();
    const speechView = new DataView(speechData);

    // Find data chunk in speech file
    let speechDataOffset = 12;
    let speechDataSize = 0;
    while (speechDataOffset + 8 < speechData.byteLength) {
        const chunkId = String.fromCharCode(
            speechView.getUint8(speechDataOffset),
            speechView.getUint8(speechDataOffset + 1),
            speechView.getUint8(speechDataOffset + 2),
            speechView.getUint8(speechDataOffset + 3),
        );
        const chunkSize = speechView.getUint32(speechDataOffset + 4, true);
        speechDataOffset += 8;
        if (chunkId === "data") {
            speechDataSize = chunkSize;
            break;
        }
        speechDataOffset += chunkSize;
    }

    const speechSamplesPerChannel = Math.floor(speechDataSize / (numChannels * bytesPerSample));

    const speechRms: number[] = [];
    for (let ch = 0; ch < numChannels; ch++) {
        speechRms.push(channelRms(speechView, speechDataOffset, numChannels, speechSamplesPerChannel, bytesPerSample, ch));
    }

    // Step 4: Show results table
    console.log("=== Channel Analysis ===");
    console.log("");

    // For multi-channel devices, PipeWire typically uses AUX0..AUXN
    const getName = (ch: number): string => {
        if (numChannels <= 2) return ch === 0 ? "FL" : "FR";
        return `AUX${ch}`;
    };

    let bestChannel = -1;
    let bestDelta = -Infinity;

    console.log("  Channel   | Silence (dB) | Speech (dB)  | Delta (dB)");
    console.log("  ----------|--------------|--------------|----------");

    for (let ch = 0; ch < numChannels; ch++) {
        const silDb = rmsToDb(silenceRms[ch]);
        const spDb = rmsToDb(speechRms[ch]);
        const delta = spDb - silDb;
        const name = getName(ch);
        const marker = delta > 3 ? " <--" : "";

        console.log(`  ${name.padEnd(10)}| ${silDb.toFixed(1).padStart(12)} | ${spDb.toFixed(1).padStart(12)} | ${delta.toFixed(1).padStart(8)}${marker}`);

        if (delta > bestDelta) {
            bestDelta = delta;
            bestChannel = ch;
        }
    }

    console.log("");

    // Step 5: Recommendation
    const bestName = getName(bestChannel);
    const speechDb = rmsToDb(speechRms[bestChannel]);

    // Cleanup
    await $`rm -f ${silenceFile} ${speechFile}`.nothrow();

    if (bestDelta < 3) {
        console.log("WARNING: No channel showed significant speech activity (delta < 3dB).");
        console.log("Make sure you spoke during the speech recording phase.");
        console.log("Falling back to AUX2.");
        return { channel: "AUX2", target: targetDevice };
    }

    console.log(`Recommended channel: ${bestName} (speech: ${speechDb.toFixed(1)} dB, delta: ${bestDelta.toFixed(1)} dB)`);
    console.log("");
    console.log(`  --pw-channel ${bestName}`);
    console.log("");
    if (speechDb < -30) {
        console.log(`Note: Signal is quiet (${speechDb.toFixed(1)} dB). Check your hardware gain settings.`);
    }

    return { channel: bestName, target: targetDevice };
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function pwDetectCli(...cliArgs: string[]) {
    let targetDevice: string | undefined;
    let duration: string | undefined;
    let doUpdateService = false;

    for (let i = 0; i < cliArgs.length; i++) {
        if (cliArgs[i] === "--update-service") {
            doUpdateService = true;
        } else if (!targetDevice) {
            targetDevice = cliArgs[i];
        } else {
            duration = cliArgs[i];
        }
    }
    const result = await pwDetect(targetDevice, duration);
    if (doUpdateService) {
        await updateServiceFile(result);
        console.log("\nService file updated. Restart with: systemctl --user restart whisper.service");
    }
}

const commands: Record<string, Function> = {
    build, rebuild, clean, setup,
    "test-stream": testStream,
    "test-pw-stream": testPwStream,
    "test-long-stream": testLongStream,
    "test-compare": testCompare,
    "pw-detect": pwDetectCli,
};

const command = process.argv[2] || "setup";
const args = process.argv.slice(3);

const fn = commands[command];
if (fn) {
    try {
        await fn(...args);
    } catch (e: any) {
        console.error(`Command failed: ${command}`, ...args);
        console.error(e.message || e);
        process.exit(1);
    }
} else {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}

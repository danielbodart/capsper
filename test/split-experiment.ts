#!/usr/bin/env bun
/**
 * Split long-recording.wav at silence boundaries and test each chunk
 * independently via streaming TCP and offline --transcribe.
 *
 * Goal: determine whether transcription degradation in long recordings
 * is a model limitation or a server state management issue.
 *
 * Usage: bun test/split-experiment.ts
 */
import { execSync, spawnSync } from "child_process";
import { mkdirSync, writeFileSync, readFileSync, copyFileSync } from "fs";
import { join } from "path";
import {
    BINARY, startServer, readPcm, streamPcmFast,
    normalize, wordEditDistance, formatAlignment, parseEmissions,
} from "./helpers";

const WAV_FILE = "test/long-recording.wav";
const REF_FILE = "test/long-recording.txt";
const CHUNK_DIR = "test/split-chunks";
const BYTES_PER_SEC = 32000;
const DOMAIN_TERMS = "test/dictation-terms.txt";

// Reference text split at the silence boundaries.
// The recording has 4 speech segments separated by 5s, 10s, and 20s silences.
const segmentRefs = [
    "Okay, I'm going to make a new recording and this recording I started at the beginning very clearly and then I'm going to talk for a bit and then I will do a stop at 15 seconds and I will stop for 5 seconds.",
    "And now I am back after 5 seconds so I'm going to continue talking for another 10 seconds and we'll get to the end there and then I'm going to stop for 10 seconds.",
    "And now I'm talking again and this time I'm going to talk for 20 seconds, see how we get on. So this will be a longer talking. I'm watching you build and add property based testing which I think is going quite well. So that's good. So I think that might have been 20 seconds.",
    "All right, so I stopped for 20 seconds that time. I'm actually not sure if I did stop, if I did talk for 20 seconds, it could have been only talking for 10 seconds. So yeah, I apologize if that is true. And now we're going to stop and this whole recording will be 1 minute 40 seconds stopping now.",
];

// --- Silence detection via RMS ---

function findSilenceBoundaries(pcm: Buffer): { start: number; end: number }[] {
    const windowBytes = 3200; // 100ms
    const silenceThreshold = 100; // RMS threshold
    const minSilenceSec = 3.0; // only detect silences > 3s

    const silences: { start: number; end: number }[] = [];
    let silenceStart: number | null = null;

    for (let offset = 0; offset + windowBytes <= pcm.length; offset += windowBytes) {
        let sumSq = 0;
        for (let i = 0; i < windowBytes; i += 2) {
            const sample = pcm.readInt16LE(offset + i);
            sumSq += sample * sample;
        }
        const rms = Math.sqrt(sumSq / (windowBytes / 2));

        if (rms < silenceThreshold) {
            if (silenceStart === null) silenceStart = offset;
        } else {
            if (silenceStart !== null) {
                const durSec = (offset - silenceStart) / BYTES_PER_SEC;
                if (durSec >= minSilenceSec) {
                    silences.push({ start: silenceStart, end: offset });
                }
                silenceStart = null;
            }
        }
    }
    // Handle trailing silence
    if (silenceStart !== null) {
        const durSec = (pcm.length - silenceStart) / BYTES_PER_SEC;
        if (durSec >= minSilenceSec) {
            silences.push({ start: silenceStart, end: pcm.length });
        }
    }

    return silences;
}

// --- WAV file writing ---

function writeWav(path: string, pcmData: Buffer): void {
    const header = Buffer.alloc(44);
    header.write("RIFF", 0);
    header.writeUInt32LE(36 + pcmData.length, 4);
    header.write("WAVE", 8);
    header.write("fmt ", 12);
    header.writeUInt32LE(16, 16); // chunk size
    header.writeUInt16LE(1, 20); // PCM format
    header.writeUInt16LE(1, 22); // mono
    header.writeUInt32LE(16000, 24); // sample rate
    header.writeUInt32LE(32000, 28); // byte rate
    header.writeUInt16LE(2, 32); // block align
    header.writeUInt16LE(16, 34); // bits per sample
    header.write("data", 36);
    header.writeUInt32LE(pcmData.length, 40);
    writeFileSync(path, Buffer.concat([header, pcmData]));
}

// --- Scoring ---

interface Score {
    label: string;
    coverage: number;
    wer: number;
    matches: number;
    subs: number;
    ins: number;
    del: number;
    total: number;
    streamText: string;
}

function scoreTranscript(streamText: string, refText: string, label: string): Score {
    const refWords = normalize(refText).split(" ").filter(Boolean);
    const streamWords = normalize(streamText).split(" ").filter(Boolean);
    const edit = wordEditDistance(refWords, streamWords);
    const total = refWords.length;
    const coverage = total > 0 ? Math.round(edit.matches * 1000 / total) / 10 : 0;
    const wer = total > 0 ? Math.round((edit.substitutions + edit.insertions + edit.deletions) * 1000 / total) / 10 : 0;

    return {
        label, coverage, wer,
        matches: edit.matches, subs: edit.substitutions, ins: edit.insertions, del: edit.deletions,
        total, streamText,
    };
}

// --- Offline transcription via --transcribe ---

function transcribeOffline(wavPath: string): string {
    const result = spawnSync(BINARY, [
        "--no-warmup", "--transcribe", wavPath,
        "--domain-terms", DOMAIN_TERMS,
    ], { timeout: 60_000 });

    if (result.status !== 0) {
        const stderr = result.stderr?.toString() ?? "";
        throw new Error(`--transcribe failed for ${wavPath}: ${stderr}`);
    }
    return result.stdout.toString().trim();
}

// --- Printing ---

function printScorecard(scores: Score[]): void {
    const pad = (s: string, w: number) => s + " ".repeat(Math.max(0, w - s.length));
    const padR = (s: string, w: number) => " ".repeat(Math.max(0, w - s.length)) + s;

    const rows = scores.map(s => ({
        name: s.label,
        cov: `${s.coverage}% (${s.matches}/${s.total})`,
        wer: `${s.wer}%`,
        subs: String(s.subs),
        ins: String(s.ins),
        del: String(s.del),
    }));

    const w = {
        name: Math.max(4, ...rows.map(r => r.name.length)),
        cov: Math.max(8, ...rows.map(r => r.cov.length)),
        wer: Math.max(3, ...rows.map(r => r.wer.length)),
        subs: Math.max(4, ...rows.map(r => r.subs.length)),
        ins: Math.max(3, ...rows.map(r => r.ins.length)),
        del: Math.max(3, ...rows.map(r => r.del.length)),
    };

    const header = `  ${pad("Test", w.name)}  ${pad("Coverage", w.cov)}  ${padR("WER", w.wer)}  ${padR("Subs", w.subs)}  ${padR("Ins", w.ins)}  ${padR("Del", w.del)}`;
    const sep = "  " + "-".repeat(header.length - 2);

    console.error("\n" + sep);
    console.error(header);
    console.error(sep);
    for (const r of rows) {
        console.error(`  ${pad(r.name, w.name)}  ${pad(r.cov, w.cov)}  ${padR(r.wer, w.wer)}  ${padR(r.subs, w.subs)}  ${padR(r.ins, w.ins)}  ${padR(r.del, w.del)}`);
    }
    console.error(sep);
}

// --- Main ---

async function main() {
    const fullPcm = readPcm(WAV_FILE);
    const fullRef = readFileSync(REF_FILE, "utf-8").trim();
    console.error(`\nTotal audio: ${(fullPcm.length / BYTES_PER_SEC).toFixed(1)}s (${fullPcm.length} bytes)\n`);

    // Step 1: Find silence boundaries
    const silences = findSilenceBoundaries(fullPcm);
    console.error(`Found ${silences.length} silence regions:`);
    for (const s of silences) {
        console.error(`  ${(s.start / BYTES_PER_SEC).toFixed(1)}s - ${(s.end / BYTES_PER_SEC).toFixed(1)}s  (${((s.end - s.start) / BYTES_PER_SEC).toFixed(1)}s silence)`);
    }

    if (silences.length !== 3) {
        console.error(`\nExpected 3 silence boundaries (5s, 10s, 20s), found ${silences.length}. Adjust threshold?`);
        process.exit(1);
    }

    // Step 2: Split PCM at silence midpoints (aligned to 2-byte sample boundary)
    const splitPoints = [
        0,
        ...silences.map(s => (Math.floor((s.start + s.end) / 2) & ~1)),
        fullPcm.length,
    ];

    mkdirSync(CHUNK_DIR, { recursive: true });
    const chunks: { pcm: Buffer; wavPath: string; ref: string; durSec: string }[] = [];

    for (let i = 0; i < splitPoints.length - 1; i++) {
        const chunkPcm = fullPcm.subarray(splitPoints[i], splitPoints[i + 1]);
        const wavPath = join(CHUNK_DIR, `chunk-${i}.wav`);
        writeWav(wavPath, chunkPcm);
        const durSec = (chunkPcm.length / BYTES_PER_SEC).toFixed(1);
        chunks.push({ pcm: chunkPcm, wavPath, ref: segmentRefs[i], durSec });
        console.error(`  Chunk ${i}: ${durSec}s → ${wavPath}`);
    }

    // Step 3: Start streaming server (same flags as long regression group)
    console.error("\nStarting streaming server...");
    const server = await startServer([
        "--port", "0", "--verbose",
        "--domain-terms", DOMAIN_TERMS,
    ]);

    const allScores: Score[] = [];

    try {
        // Step 4: Test full file via streaming (baseline — matches current regression test)
        console.error("\n--- Full file via streaming TCP ---");
        {
            const output = await streamPcmFast(server.port, fullPcm);
            const emissions = parseEmissions(output);
            const streamText = emissions.map(e => e.text).join(" ").replace(/\s+/g, " ").trim();
            const score = scoreTranscript(streamText, fullRef, "full-stream");
            allScores.push(score);
            console.error(`  ${score.label}: coverage=${score.coverage}% wer=${score.wer}%`);
        }

        // Step 5: Test each chunk via streaming TCP
        console.error("\n--- Individual chunks via streaming TCP ---");
        for (let i = 0; i < chunks.length; i++) {
            const { pcm, ref, durSec } = chunks[i];
            const output = await streamPcmFast(server.port, pcm);
            const emissions = parseEmissions(output);
            const streamText = emissions.map(e => e.text).join(" ").replace(/\s+/g, " ").trim();
            const score = scoreTranscript(streamText, ref, `chunk-${i}-stream (${durSec}s)`);
            allScores.push(score);
            console.error(`  ${score.label}: coverage=${score.coverage}% wer=${score.wer}%`);
        }

        // Step 5b: Test segments split at silence START (mimics what server reads after flush)
        // After flush, server reads from the start of the silence gap. This tests whether
        // having leading silence in a fresh connection matters.
        console.error("\n--- Segments split at silence starts via streaming TCP ---");
        const silenceStartSplits = [
            0,
            ...silences.map(s => s.start & ~1),
            fullPcm.length,
        ];
        for (let i = 0; i < silenceStartSplits.length - 1; i++) {
            const segPcm = fullPcm.subarray(silenceStartSplits[i], silenceStartSplits[i + 1]);
            const durSec = (segPcm.length / BYTES_PER_SEC).toFixed(1);
            const output = await streamPcmFast(server.port, segPcm);
            const emissions = parseEmissions(output);
            const streamText = emissions.map(e => e.text).join(" ").replace(/\s+/g, " ").trim();
            const score = scoreTranscript(streamText, segmentRefs[i], `seg-${i}-silstart (${durSec}s)`);
            allScores.push(score);
            console.error(`  ${score.label}: coverage=${score.coverage}% wer=${score.wer}%`);
        }
    } finally {
        // Save server log for analysis
        const logDest = join(CHUNK_DIR, "server.log");
        try { copyFileSync(server.logFile, logDest); } catch {}
        console.error(`\nServer log saved to ${logDest}`);
        server.kill();
    }

    // Step 6: Test full file via --transcribe (offline baseline)
    console.error("\n--- Full file via --transcribe (offline) ---");
    {
        const text = transcribeOffline(WAV_FILE);
        const score = scoreTranscript(text, fullRef, "full-offline");
        allScores.push(score);
        console.error(`  ${score.label}: coverage=${score.coverage}% wer=${score.wer}%`);
    }

    // Step 7: Test each chunk via --transcribe
    console.error("\n--- Individual chunks via --transcribe (offline) ---");
    for (let i = 0; i < chunks.length; i++) {
        const { wavPath, ref, durSec } = chunks[i];
        const text = transcribeOffline(wavPath);
        const score = scoreTranscript(text, ref, `chunk-${i}-offline (${durSec}s)`);
        allScores.push(score);
        console.error(`  ${score.label}: coverage=${score.coverage}% wer=${score.wer}%`);
    }

    // Step 8: Print comparative scorecard
    console.error("\n\n========== RESULTS ==========");
    printScorecard(allScores);

    // Step 9: Print detailed diffs for each score
    for (const s of allScores) {
        const refText = s.label.startsWith("full") ? fullRef : segmentRefs[parseInt(s.label.match(/chunk-(\d+)/)?.[1] ?? "0")];
        const refWords = normalize(refText).split(" ").filter(Boolean);
        const streamWords = normalize(s.streamText).split(" ").filter(Boolean);
        const edit = wordEditDistance(refWords, streamWords);
        console.error(`\n--- ${s.label} ---`);
        console.error(formatAlignment(edit));
    }
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});

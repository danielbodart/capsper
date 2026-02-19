# Dictation Review

Analyze captured debug recordings to find transcription issues and create regression tests.

## Steps

1. **Find recordings**: List all `.log`/`.wav` pairs in the record directory (default: `~/.local/share/capsper/recordings/`). If no recordings exist, tell the user to enable recording with `--record-dir` and speak some utterances.

2. **For each recording**:
   - Read the `.log` file and extract the "Emitted Text" section (what streaming mode produced)
   - Batch-transcribe the `.wav` file using: `./dist/bin/capsper --transcribe <file> --model <model> --vad-model <vad-model> 2>/dev/null`
     - Model paths: check the systemd service file at `~/.config/systemd/user/capsper.service` for the `--model` and `--vad-model` paths, or fall back to `whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin` and `whisper.cpp/models/ggml-silero-v5.1.2.bin`
   - Compare streaming vs batch output, normalizing both (lowercase, strip punctuation except apostrophes)
   - Calculate the WAV duration: `(file_size - 44) / 32000` seconds

3. **Identify issues** in each recording:
   - **Dropped words**: words in batch but missing from streaming (especially at the end — the "last word drop" problem)
   - **Duplicate words**: words that appear twice consecutively in streaming but only once in batch
   - **Extra words**: words in streaming that don't appear in batch (hallucinations)
   - **Spelling variants**: minor differences like "okay"/"OK", "alright"/"all right" (note but deprioritize)

4. **Report findings**: Present a summary table showing each recording with its duration, word count, and issues. Highlight the most interesting cases for regression testing.

5. **Create regression tests** (if interesting issues found):
   - Ask the user which recordings to turn into tests
   - Copy the `.wav` to `test/<name>.wav`
   - Write the ground-truth transcript (based on batch output, manually corrected if needed) to `test/<name>.txt`
   - Add the test case to `test/regression.test.ts` in the correct group based on duration:
     - **Short** (`shortCases`): < 15s — runs in `./run.ts` default and `./run.ts short-test`
     - **Medium** (`mediumCases`): 15-40s — runs in `./run.ts medium-test`
     - **Long** (`longCases`): > 60s — runs in `./run.ts long-test`
   - Use the `TestCase` interface: `{ name: "<name>", wav: "test/<name>.wav", ref: "test/<name>.txt" }`
   - Add custom `thresholds` only if needed (defaults: `minCoverage: 85, maxMissed: 25, maxExtras: 15, maxGapSec: 10, maxRepetitions: 5`)
   - Known issue: files > 60s degrade significantly with fast-forward TCP streaming due to phrase-level repetition overwhelming the 30s buffer. Set loose thresholds (minCoverage: 20, maxExtras: 400+) for long files.
   - If the recording has domain-specific vocabulary, consider adding a `test/<name>-terms.txt` file and note that the long group server already passes `--domain-terms test/dictation-terms.txt`
   - Run the appropriate test to get a baseline: `./run.ts short-test`, `./run.ts medium-test`, or `./run.ts long-test`
   - Report the baseline coverage so future improvements can be measured

## Test Infrastructure Reference

### Test groups in `test/regression.test.ts`

Each group shares a single server instance (saves GPU warmup time):
- `shortCases` — fast TCP, no extra server args
- `mediumCases` — fast TCP, no extra server args
- `longCases` — fast TCP, server gets `--domain-terms test/dictation-terms.txt`

### Running tests

```bash
./run.ts short-test     # short group only (~6s)
./run.ts medium-test    # medium group only (~13s)
./run.ts long-test      # long group only (~70s)
./run.ts slow-test      # ALL groups + long-stream stability + pw plumbing
```

### Debug logs

After any test run, server stderr is saved to `test/results/<group>.log` (e.g. `test/results/short.log`). These contain:
- VAD decisions (speech/silence transitions)
- Transcription cycle details (buffer size, token counts, timing)
- Pipeline events (rewind, repetition guard, attention stopping)
- Emission timeline

### Assertions (`assertTranscript` in `test/helpers.ts`)

Every test gets these checks:
- **Coverage**: percentage of reference words found in stream output
- **Missed words**: reference words not found in stream
- **Extras**: stream words beyond matched count (duplicates/hallucinations)
- **Gap detection**: maximum time between consecutive emissions
- **Repetition detection**: consecutive identical words (threshold configurable)

### Fast-forward streaming

Tests use `streamPcmFast()` which sends all PCM in one TCP write + half-close (via `Bun.connect` + `socket.shutdown()`). No real-time pacing. The server's 100ms poll timeout detects when data stops arriving. This makes short/medium tests ~10x faster than real-time.

## Notes

- The "last word drop" and "duplicate word" issues are the primary targets for improvement
- The cycle log in `.log` files shows exactly when each word was emitted and the stability state, which helps diagnose timing-related issues
- Short recordings (< 15s) make the best regression tests — fast, reproducible, and fast-forward produces identical results to real-time
- For long recordings with quality issues, prefer splitting into shorter segments that isolate the specific problem

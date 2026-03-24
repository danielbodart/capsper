# Dictation Review

Analyze captured debug recordings to find transcription issues and create regression tests.

## Steps

1. **Find recordings**: List all `.log`/`.wav` pairs in the record directory (default: `~/.local/share/capsper/recordings/`). If no recordings exist, tell the user to enable recording with `--record-dir` and speak some utterances.

2. **Find model path**: Check the service config for the `--model` path:
   - **Linux**: parse `~/.config/systemd/user/capsper.service` for the `ExecStart=` line
   - **macOS**: parse `~/Library/LaunchAgents/com.capsper.capsper.plist` with `plutil -convert json -o - | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin).get('ProgramArguments',[])))"`
   - Fall back to `dist/models/nemotron`

3. **For each recording**:
   - Read the `.log` file and extract the "Emitted Text" section (what streaming mode produced)
   - Batch-transcribe the `.wav` file using: `./dist/bin/capsper --transcribe <file> --model <model> 2>/dev/null`
   - Compare streaming vs batch output, normalizing both (lowercase, strip punctuation except apostrophes)
   - Calculate the WAV duration: `(file_size - 44) / 32000` seconds

4. **Identify issues** in each recording:
   - **Dropped words**: words in batch but missing from streaming (especially at the end — the "last word drop" problem)
   - **Duplicate words**: words that appear twice consecutively in streaming but only once in batch
   - **Extra words**: words in streaming that don't appear in batch (hallucinations)
   - **Spelling variants**: minor differences like "okay"/"OK", "alright"/"all right" (note but deprioritize)

5. **Report findings**: Present a summary table showing each recording with its duration, word count, and issues. Highlight the most interesting cases for regression testing.

6. **Create regression tests** (if interesting issues found):
   - Ask the user which recordings to turn into tests
   - Copy the `.wav` to `test/<name>.wav`
   - Write the ground-truth transcript (based on batch output, manually corrected if needed) to `test/<name>.txt`
   - Add the test case to `test/regression.test.ts` in the correct group based on duration:
     - **Short** (`shortCases`): < 15s — runs in `./run.ts` default and `./run.ts short-test`
     - **Medium** (`mediumCases`): 15-40s — runs in `./run.ts medium-test`
     - **Long** (`longCases`): > 60s — runs in `./run.ts long-test`
   - Use the `TestCase` interface: `{ name: "<name>", wav: "test/<name>.wav", ref: "test/<name>.txt" }`
   - Add custom `thresholds` only if needed (defaults: `minCoverage: 85, maxWer: 30, maxGapSec: 10, maxRepetitions: 5`)
   - Primary quality target: files > 60s with long continuous speech degrade as the 30s sliding window trims old audio and context is lost. Set loose thresholds (minCoverage: 20, maxWer: 500) for long files and tighten as we improve.
   - If the recording has domain-specific vocabulary, consider adding a `test/<name>-terms.txt` file and note that the long group server already passes `--drop-terms test/dictation-terms.txt`
   - Run the appropriate test to get a baseline: `./run.ts short-test`, `./run.ts medium-test`, or `./run.ts long-test`
   - Report the baseline coverage so future improvements can be measured

## Test Infrastructure Reference

### Test groups in `test/regression.test.ts`

Each group shares a single server instance (saves warmup time):
- `shortCases` — fast TCP, no extra server args
- `mediumCases` — fast TCP, no extra server args
- `longCases` — fast TCP, server gets `--drop-terms test/dictation-terms.txt`

### Running tests

```bash
./run.ts short-test     # short group only (~6s)
./run.ts medium-test    # medium group only (~13s)
./run.ts long-test      # long group only (~70s)
./run.ts slow-test      # ALL groups + long-stream stability + platform plumbing
```

### Test output

Tests automatically save all logs to `test/results/`:
- **`<group>.log`** — Server log (transcription cycles, pipeline events, timing)
- **`<group>-scoring.log`** — Scoring detail per test (emission timeline, coverage/WER metrics, inline word diff)

Console output shows only the scorecard summary table. For detailed diagnostics, read the files above.

### Assertions (`assertTranscript` in `test/helpers.ts`)

Every test gets these checks (using Wagner-Fischer word edit distance):
- **Coverage**: percentage of reference words correctly matched in stream output
- **WER** (Word Error Rate): `(substitutions + insertions + deletions) / reference_words * 100`
- **Substitutions**: reference words replaced by different words
- **Insertions**: extra words in stream not in reference (hallucinations)
- **Deletions**: reference words missing from stream
- **Gap detection**: maximum time between consecutive emissions
- **Repetition detection**: consecutive identical words (threshold configurable)

### Fast-forward streaming

Tests use `streamPcmFast()` which sends all PCM in one TCP write + half-close (via `Bun.connect` + `socket.shutdown()`). No real-time pacing. The server's 100ms poll timeout detects when data stops arriving. This makes short/medium tests ~10x faster than real-time.

## Notes

- **Hallucination suppression**: If review reveals short hallucinated phrases (e.g. "Thank you.", "I love you") appearing as entire segments, add them to a `--drop-terms` file rather than trying to fix other parameters. Drop terms suppress exact single-chunk matches.
- The "last word drop" and "duplicate word" issues are the primary targets for improvement
- The cycle log in `.log` files shows exactly when each word was emitted and the stability state, which helps diagnose timing-related issues
- Short recordings (< 15s) make the best regression tests — fast, reproducible, and fast-forward produces identical results to real-time
- For long recordings with quality issues, prefer splitting into shorter segments that isolate the specific problem

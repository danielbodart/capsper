# Dictation Review

Analyze captured debug recordings to find transcription issues and create regression tests.

## Steps

1. **Find recordings**: List all `.log`/`.wav` pairs in the record directory (default: `~/.local/share/capsper/recordings/`). If no recordings exist, tell the user to enable recording with `--record-dir` and speak some utterances.

2. **For each recording**:
   - Read the `.log` file and extract the "Emitted Text" section (what streaming mode produced)
   - Batch-transcribe the `.wav` file using: `./dist/bin/capsper --transcribe <file> --model <model> --vad-model <vad-model> 2>/dev/null`
     - Model paths: check the systemd service file at `~/.config/systemd/user/capsper.service` for the `--model` and `--vad-model` paths, or fall back to `whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin` and `whisper.cpp/models/ggml-silero-v5.1.2.bin`
   - Compare streaming vs batch output, normalizing both (lowercase, strip punctuation except apostrophes)

3. **Identify issues** in each recording:
   - **Dropped words**: words in batch but missing from streaming (especially at the end — the "last word drop" problem)
   - **Duplicate words**: words that appear twice consecutively in streaming but only once in batch
   - **Extra words**: words in streaming that don't appear in batch (hallucinations)
   - **Spelling variants**: minor differences like "okay"/"OK", "alright"/"all right" (note but deprioritize)

4. **Report findings**: Present a summary table showing each recording with its issues. Highlight the most interesting cases for regression testing.

5. **Create regression tests** (if interesting issues found):
   - Ask the user which recordings to turn into tests
   - Copy the `.wav` to `test/<name>.wav`
   - Write the ground-truth transcript (based on batch output, manually corrected if needed) to `test/<name>.txt`
   - Run `./run.ts slow-test compare <name>` to get a baseline coverage score
   - Report the baseline so future improvements can be measured

## Notes

- The compare test infrastructure already handles normalization and word-level comparison
- Focus on short recordings (< 30s) for regression tests — they're faster and more reproducible
- The "last word drop" and "duplicate word" issues are the primary targets for improvement
- The cycle log in `.log` files shows exactly when each word was emitted and the stability state, which helps diagnose timing-related issues

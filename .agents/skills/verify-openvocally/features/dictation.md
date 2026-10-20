# Dictation

The user holds a shortcut, speaks and releases, or presses once to start and once to stop. The overlay shows recording, then transcribing, and the text is pasted into the front app and saved to history.

## Sub-features

- `dictation-ptt` hold to talk: press, hold, release.
- `dictation-toggle` press to start, press again to stop.
- `dictation-text` the pasted text matches what was said.
- `dictation-lb01` press to visible recording feedback, budget under 100 ms p95.
- `dictation-lb02` release to pasted text, budget under 250 ms p95 for a 5 s phrase.
- `dictation-history` the dictation is saved to history.

## How to get to it (user POV)

- Hold the push-to-talk shortcut set in **Settings** > **Shortcuts**, speak, release.
- Press the toggle shortcut, speak, press it again.
- Choose **Start Dictation** in the menu bar menu.

## Driving it with the scripts

Preconditions:

- The doctor lists at least one model. Without `--model`, the runs use the active model, the one the app last used.
- The Apple models (`apple-dictation-transcriber`, `apple-speech-transcriber`) need macOS 26 or newer. macOS installs their files, not the app, so the doctor's model folder never lists them.

- **Hold to talk.** Run `scripts/latency/dictation-harness.sh --runs 3`. Exit code 0. Each `run N:` line shows `match=True`, and the summary in `results.jsonl` reads `"matched":3,"runs":3`.
- **Toggle.** Run `scripts/latency/dictation-harness.sh --runs 3 --mode toggle`. Same result.
- **One model or every model.** Run `scripts/latency/dictation-harness.sh --runs 10 --model all`, or `--model large-v3-turbo` for one. The ids are the `ModelID` raw values in `OpenVocallyKit/Sources/Models/ModelCatalog.swift`. The app loads each model in its own launch and keeps its active model. A model that isn't installed prints `Skipped:` and does not fail the run. The closing table has one row per model with the median and max of LB-01, LB-02 and the word error rate. `make dictation-harness MODEL=all HARNESS_RUNS=10` does the same.
- **Apple models.** Run `scripts/latency/dictation-harness.sh --runs 5 --model apple-dictation-transcriber`, then the same with `apple-speech-transcriber`. macOS keeps speech languages per app, so the harness installs the model's language for the Debug app first, which can download it when macOS lacks it. The run uses the language of the fixture's voice through launch arguments, so the language stored in the app never changes. Apple Speech doesn't support Polish, so run the `pl-` fixtures on Apple Dictation only. Before macOS 26 the model prints `Skipped:`.
- **Another language.** Run `scripts/latency/dictation-harness.sh --runs 3 --fixture pl-short`. Fixtures are listed in `scripts/fixtures/fixtures.tsv`.
- **Latency.** Read `latency.txt` in the evidence folder. The `LB-01` and `LB-02` rows each have n equal to the run count and give median, p95 and max in ms. Report the p95 against the budgets above. The stage rows split LB-02 into transcribe, process and other.
- **History.** Each run saves to the scratch data folder, which is deleted afterwards. The real database must keep its modification time: run `stat -f %m "$HOME/Library/Application Support/com.openvocally.app.debug/openvocally.sqlite"` before and after.
- **Proof.** `.build/dictation-harness/<timestamp>/` holds `scenario.json`, `results.jsonl` and `latency.txt`.

## Gotchas

- The harness replaces the microphone with the fixture, the key press with a scripted press and the paste with a recorder. A change to the real hotkey tap, the microphone capture or the paste needs the user to check it by hand; say so instead of calling it verified.
- The fixture plays in real time from the press, so the recording tail stage is empty and no sound cue plays.
- LB-02 depends on the model. Report the model with the number.
- The Apple models stream: they transcribe while the fixture plays, so their LB-02 is mostly the final pass after the release.
- `--runs` is 1 to 10. Report the median and the max.
- Each run may last the fixture's length plus 30 s. `en-long` is 70 s, so keep it to 3 runs or raise `TIMEOUT` past 300 s.
- A match allows a word error rate up to 0.1. Empty or cut-off text always fails.

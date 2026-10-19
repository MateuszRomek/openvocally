# Measure release-to-text latency per model

`model-bench` measures how long each local model takes from push-to-talk release to final text, and
how much a "transcribe during recording" strategy shortens that. Use it to compare strategies on one
machine, or to check a model change against the targets: tier 1 under 250 ms, tier 2 under 500 ms.

## What it measures

Each fixture is played into a strategy in 20 ms chunks (320 samples at 16 kHz), one chunk every
20 ms by default, as a microphone delivers them.

- **Start:** the last `append` call returns. This stands for the release.
- **Lead-in:** timed run `n` waits `n % 10` × 100 ms between the press (`start`) and the first
  chunk. The runtime pings the engine about once a second while recording, so the lead-in
  spreads the releases of equal-length runs across that period instead of hitting one phase.
- **Stop:** the strategy's `finish` call returns the text.

The clock covers engine time only. It does not include the app's tail wait after release, the paste,
or the model load. Each model loads once, before anything is timed, as the app loads it at launch.

Time spent inside `append` is recorded separately as `append_busy_ms`: the work a strategy does while
the user is still talking.

Each strategy and fixture gets one warmup run that is discarded, then the timed runs, each after a
500 ms idle pause. While a model loads and is timed, the bench holds an exclusive lock on
`/tmp/openvocally-model-bench.lock`, so two benches never time on a machine the other is
loading. A waiting bench prints a line.

## Run it

```sh
make model-bench                                    # every installed model, every strategy
make model-bench MODELS=parakeetV3 RUNS=5
make model-bench MODELS=whisperTurbo STRATEGIES=batch FIXTURES=en-short,en-30s
```

The binary takes the same options and more; `--help` lists them with the registered strategies and
the fixtures:

```sh
swift run -c release --package-path scripts/latency/model-bench model-bench --help
```

- **Models:** `parakeetV3`, `parakeetUltra`, `whisperTurbo`, or `all`. By default every installed
  model runs. The bench searches the Release app's model folder, then the Debug app's, and skips a model it cannot find with a printed line.
- **Fixtures:** the default set is `en-short`, `en-noisy`, `pl-short`, `silence` (from
  `scripts/fixtures`) and `en-1s`, `pl-1s`, `en-quiet-end`, `noise-3s`, `pl-numbers`,
  `en-15s`, `en-30s` (from `fixtures/`). `all` adds `en-29s`, `en-31s` and the long
  fixtures; name any of them to run it alone.
- **No speech:** a fixture whose reference is empty or `-` (`silence`, `noise-3s`) expects no
  text. A run that reports no speech counts as a success with empty text; its WER is 0 for no
  text and 1 for any text.
- **Runs:** `--runs` (default 20) applies to fixtures under 10 s. Longer fixtures get half as many.
- **Pace:** `--pace realtime` (default), `instant` or `settled`. `instant` appends every chunk
  back to back. `settled` also appends back to back, then holds the release until the runtime has
  done all the work it would do on the recording before the release: it has listened to the whole
  recording twice in a row with no engine call between, or, once it stops listening, made no
  `transcribe` call for 1.5 s. The release then sees what a realtime run sees, so a 70 s fixture
  costs seconds instead of 70 s. A run that does not settle within 60 s fails. `batch` has no
  runtime, so for it `settled` is `instant`. Use `settled` to iterate; the before and after
  numbers a change reports must come from `--pace realtime`.
- **Plan:** `--plan` loads no model. For each selected model and fixture it prints the inputs the
  runtime started while recording and the inputs the release decoded, in seconds, for example
  `en-15s  early: 0.00-10.89  release: 10.89-14.66`. It uses the engine's real lookahead and an
  engine that returns at once, and respects `--models` and `--fixtures`.
- **Quick check:** `make model-bench-quick` runs Whisper `shipping` on `en-short` and `en-long`,
  3 runs each, at the settled pace.
- **Release gap:** `--release-gap-ms` appends that much digital silence before the release, for a
  user who stops talking and then lets go of the key. The fixtures end about 200 ms after the last
  word. The runtime transcribes at a pause while the user records, so its gain shows only
  when the gap leaves time for that call.

A full run of four models takes about an hour. Keep the machine otherwise idle while it runs.

## Read the results

Results go to `results/<timestamp>/` in this folder (git-ignored), or to `--out`.

| File | Contents |
| --- | --- |
| `summary.tsv` | One row per model, strategy and fixture. |
| `results.jsonl` | One line per timed run. |
| `meta.json` | Chip, memory, macOS, git commit and dirty flag, load average, thermal state at start and end, start and end time, arguments, and what happened to each model. |

`summary.tsv` columns:

| Column | Meaning |
| --- | --- |
| `model`, `strategy`, `fixture` | What ran. |
| `audio_s` | Fixture length in seconds. |
| `n` | Successful timed runs. |
| `median_ms`, `p95_ms`, `min_ms`, `max_ms` | Release to text. p95 is nearest rank. |
| `mean_wer` | Mean word error rate against the fixture's reference: lowercase, punctuation removed. |
| `tier` | 1 when p95 is under 250 ms, 2 under 500 ms, else 3. Engine time only. |
| `repeats` | Successful runs whose text repeats a phrase of 3 or more words that the reference does not. |

`results.jsonl` keys: `model`, `strategy`, `fixture`, `pace`, `audio_s`, `run`, `release_to_text_ms`,
`append_busy_ms`, `max_append_lag_ms` (how late an append started after its chunk was due),
`fell_behind` (the last append returned more than 20 ms after the audio ended), `thermal`, `text`,
`wer`, `error` for a failed run, `release_gap_ms`, `repeated_words` (the longest phrase said twice
in a row, in words) and `repeats` (`repeated_words` is 3 or more and longer than the reference's).

New keys and columns are added at the end. Existing ones are never renamed.

## Add a strategy

1. Add a file in `Sources/model-bench/Experiments/` with an `actor` that conforms to `Strategy`
   (`Sources/model-bench/Core/Strategy.swift`) for one engine's model type: `ParakeetModel`
   or `WhisperModel`.
2. Add the type to that engine's list in `Sources/model-bench/Engines/Registry.swift`.
3. If the strategy needs engine internals, add fields to the engine's model in
   `Sources/model-bench/Engines/` and load them there. Copying shipping code into this package is
   fine; shipping code never depends on it.

Two strategies are built in for every engine:

- `shipping` is what the app does. It drives the real `TranscriptionRuntime`: `warm(listening:)` at
  the press, which keeps the engine warm and transcribes at pauses while recording, and
  `transcribe` at the release. Run it to check a model against the tiers.
- `batch` calls the engine once after release with no warming. It is the floor to compare
  experiments against.

The change that ships a winning strategy moves it into the runtime or the engine, so `shipping`
picks it up, and deletes the experiment.

To build without disturbing another build, pass your own scratch path:
`swift build -c release --package-path scripts/latency/model-bench --scratch-path <dir>`.

## Fixtures

The WAVs in `fixtures/` are synthesized with `say` from `fixtures/fixtures.tsv`, which names each
fixture's voice, the silence after its last word (`after_s`) and its reference text. To regenerate them, run `scripts/latency/model-bench/make-fixtures.sh`.
The committed WAVs are the reference, because voices change between macOS releases.

# Latency budgets

Local dictation must feel instant. These budgets set what "instant" means in milliseconds. They are absolute targets.

## Budgets

| ID | Measurement | Budget | Why this number |
| --- | --- | --- | --- |
| LB-01 | Push-to-talk press to visible recording feedback (overlay shows recording) | p95 under 100 ms, cold and warm mic | About 100 ms is where a response reads as instant. |
| LB-02 | Push-to-talk release to pasted text, for the 5 s `en-short` fixture | p95 under 250 ms | In-process Parakeet transcribes `en-short` in about 157 ms median, which leaves about 90 ms for stop, paste and focus. |
| LB-03 | Speech that starts at the press | The first word is in the transcript | A clipped first word is the failure users notice most. |

### Model tiers

Each local model gets a tier from its release-to-text p95 over the whole flow on the reference M1 Pro. The tier tells the user how fast a model is. It does not change LB-02, which every default model must meet.

| Tier | Release-to-text p95 | Meaning |
| --- | --- | --- |
| 1 | under 250 ms | Instant. Meets LB-02. |
| 2 | under 500 ms | Usable, but noticeably slower. |
| 3 | 500 ms or more | Slow. |

`scripts/latency/model-bench` reports a tier from engine time only. `make dictation-harness MODEL=all HARNESS_RUNS=10` measures the whole flow for every installed model. Add the text drawn in the target app before assigning a model its tier.

### Transcripts and Home

Measured with `make transcripts-latency` (`scripts/latency/transcripts-latency.sh --help`) on a seeded database. The budget applies at 50,000 transcripts, the default size; `--rows all` also runs 1,000 and 10,000, and `--scenario` runs one part in seconds.

| ID | Measurement | Budget | Why this number |
| --- | --- | --- | --- |
| LB-04 | Opening Home or Transcripts, or switching between them, to its content shown | p95 under 100 ms, and the first Transcripts open after launch under 150 ms | The same instant-response limit as LB-01. The first open builds the list once, so it gets more time. |
| LB-05 | Load more: the next 30 transcripts shown after the list reaches its end | p95 under 50 ms | Rows must arrive before the user scrolls into the empty end. |
| LB-06 | A saved dictation shown as the top Transcripts row, and Home updated after a save | p95 under 50 ms, flat with the number of transcripts | The user sees the result next to the paste. |
| LB-07 | Sidebar collapse and expand, on Home and Transcripts | No frame over 60 ms, and no one-frame layout step over 90 pt | A step of the whole width in one frame is the jump users notice. The SwiftUI split view can't hold the stricter LB-08 budget. |
| LB-08 | Transcript detail open and close at 10 pages loaded | No frame over 33 ms, and no one-frame layout step over 80 pt | It is the same kind of split-view motion, and it meets the first LB-07 budget. |
| LB-09 | Scrolling the Transcripts list at 1 to 20 pages | No frame over 33 ms | Scrolling must stay smooth. |
| LB-10 | Memory footprint with 20 pages loaded | Under 150 MB | A long history must not grow memory without limit. |

Cold mic means the input device is closed at the press. Warm mic means it is still open from a recent recording. Report both for LB-01.

Change a budget in a pull request that says why.

## Where the numbers come from

- Under 100 ms, people feel that their own action caused the result. Under 1 s, their train of thought holds. These are Nielsen's response-time limits, which go back to Miller (1968).
- LB-02 ends at the paste key post, so it stops before the target app draws the text. Add that last step before comparing LB-02 with a measurement taken on screen.

Sources: [Nielsen, the three response-time limits](https://www.nngroup.com/videos/3-response-time-limits-interaction-design/), [Nielsen, time scales of UX](https://www.uxtigers.com/post/time-scales-ux).

## How to measure

The app measures its own instants in process. No UI automation is needed.

- Press and release are the timestamps of the key events that the `Hotkeys` event tap receives (`CGEventGetTimestamp`).
- Visible recording feedback is the moment the overlay has laid out and drawn the recording phase into its window. The compositor's next frame, up to one display refresh, is not included.
- Pasted text is the moment the paste key-down event is posted.
- Emit each instant as an `os_signpost` so Instruments and a test can read them.
- Report the median and max of 10 runs on one machine, with the chip and macOS version. At 10 runs the p95 is the slowest run.
- Compare frame counts only on the same display. A frame that misses one refresh counts over 16.7 ms at 120 Hz but not at 144 Hz. Launch times on a loaded machine vary up to two times, so judge a change on interleaved launches.

A PR that touches the hot path reports these numbers before and after.


# Notch agents lab (throwaway)

A prototype for deciding how the one notch surface looks and behaves for agent threads and dictation: closed, peeking and open as a thread panel, on a MacBook notch and on displays without one. It is not part of the app. Delete it once the decision is recorded.

## Run it

```sh
swift run --package-path prototypes/notch-agents
```

A control window opens, and every display gets its own non-activating panel at the top center.

| Where | Key | Action |
| --- | --- | --- |
| Control window | Hold Space | Dictation: recording, transcribing, Pasted |
| Control window | Hold A | Agent mode into the selected thread |
| Control window | O, Esc | Open, close the panel |
| Any app | Hold right ⌥, right ⌘ | Dictation, agent mode (needs Accessibility for the terminal) |
| Notch | Hover, click | Peek, open |
| Open panel, list | ↑ ↓, Return, ⌘N | Move, open the thread, new thread |
| Open panel, thread | Esc or ⌘[, ⌘O, ⌘↩, ⌘⌫ | Back, open in the main window, allow, deny |
| Any app, approval pending | ⌥↩, ⌥⎋ | Allow, deny the front card; with no card on screen, the first press shows it |
| Approval card | Click a button, click the card | Answer without taking focus, open the thread |

## What it compares

- **Displays:** only the one with the pointer (the default), every display with a menu bar, every display, or only the main one.
- **Without a notch:** a plain notch on the menu bar, the notch with dark shoulders, the notch with a drop shadow, or a pill below the menu bar. The simulated notch is as tall as the menu bar or 32 pt, and either rests in place or disappears when idle.
- **Behavior:** hover peeks or opens, the panel closes when the pointer leaves or on Esc or a click outside, three open springs, and three working indicators. Closing is quicker than opening, and opening or closing from the keyboard is near-instant. The black shape springs to reveal content that is already laid out at its final size, so text never re-wraps mid-motion.
- **Approvals:** what the closed notch does when one arrives (the Needs you mark only, one line for 4 s, or a card with buttons), several at once (one card with 1 of N, the front card with the rest stacked, or every card listed), the command in full or on one line, Allow for this thread as a button or in a menu, whether the card stays or shrinks after 8 s, and which thread agent mode speaks to while a card shows. Speaking to a thread with a pending approval denies it and sends what you said as the reason. The Long command and Risky tail sequences test how much of a command you see.
- **Dictation in the same shape:** recording, transcribing and Pasted in the closed row; agent mode can name its target thread under the camera; in the open panel the reply box turns into the meter.

The panel takes keyboard focus only while open, and never activates the lab, so the app you were typing in stays frontmost. Clicks reach the panel only inside the drawn shape.

## Screenshots without the control window

```sh
.build/debug/NotchAgentsLab --backdrop pill --demo busy --open
```

Flags: `--backdrop shoulders|shadow|pill`, `--resting`, `--preview`, `--size compact|roomy|large`, `--demo busy|needs|answer|many|failed|record|agent|approvals|long|tail`, `--thread <id>`, `--arrival mark|peek|card`, `--queue oneAtATime|stacked|list`, `--one-line`, `--allow-menu`, `--speak-after <seconds>`, `--everywhere`, `--passive`, then `--open` last. Use `--passive` while someone is typing: it never activates the lab or gives the panel keyboard focus. AppKit reads `--open x` as a defaults pair and opens any leftover word as a file, which quits the lab.

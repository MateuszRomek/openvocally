# Onboarding

On first launch the user walks through welcome, permissions, shortcut, model download and a Try it step that listens for a real hold.

## Sub-features

- `onboarding-steps` each step renders: welcome, permissions, shortcut, model, tryIt.
- `onboarding-download` the model step downloads into an empty model folder.

## How to get to it (user POV)

- First launch of a fresh install.
- **Settings** > **Setup** > **Welcome tour** > **Show Again**.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **Every step.** Run `make onboarding-shots`, or `scripts/onboarding/shots.sh model tryIt` for some steps. Open each `.build/onboarding-shots/<step>.png` and check the step's title and controls.
- **Model download.** Run `make onboarding FRESH=1 STEP=model`. It points the app at an empty `.build/onboarding-models` folder, so the download never touches the installed models. This downloads a model over the network and needs the user to click; skip it unless the change touches the download.

## Gotchas

- The permissions and Try it steps read the real Microphone and Accessibility state. A screenshot shows the current grants, not a fresh install.
- Screenshots never click through, so the move between steps is not covered.

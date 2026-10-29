.PHONY: whisper generate lint format test build check run onboarding onboarding-shots smoke-idle overlay-demo install dictation-latency capture-latency device-change device-change-bluetooth speech-check-bluetooth transcripts-latency model-bench model-bench-quick dictation-harness gallery-shots diagnostics-export release update-e2e

# Patched whisper.cpp. Rebuilds only when its script or patch changes.
whisper:
	./scripts/whisper/build-xcframework.sh

generate: whisper
	xcodegen generate --quiet

lint:
	swift format lint --strict --recursive App OpenVocallyKit scripts/latency/capture-probe \
	  scripts/latency/model-bench
	./scripts/check-banned-apis.sh
	./scripts/check-public-api.py
	./scripts/check-references.sh
	./scripts/check-design-tokens.sh
	./scripts/check-overlay-motion.sh
	./scripts/attributions/generate.py --check
	./scripts/lint-scripts.sh
	./scripts/latency/check-dictation-latency.sh

format:
	swift format format --in-place --recursive App OpenVocallyKit scripts/latency/capture-probe \
	  scripts/latency/model-bench

test: whisper
	swift test --package-path OpenVocallyKit
	swift build --package-path scripts/latency/capture-probe
	swift build --package-path scripts/latency/model-bench
	swift test --package-path scripts/latency/model-bench

build: generate
	scripts/build-debug.sh

check: lint test build

run:
	./scripts/run-debug.sh

# Debug build that shows the first-run onboarding again; STEP=shortcut opens on one step.
onboarding:
	@if [ -n "$(FRESH)" ]; then \
		rm -rf .build/onboarding-models; \
		./scripts/run-debug.sh -onboarding YES -onboardingStep $${STEP:-welcome} -modelFolder "$$PWD/.build/onboarding-models"; \
	else \
		./scripts/run-debug.sh -onboarding YES -onboardingStep $${STEP:-welcome}; \
	fi

# Writes a PNG of each onboarding step's window to .build/onboarding-shots, without taking focus.
onboarding-shots:
	./scripts/onboarding/shots.sh

# Writes a PNG of each Design Gallery section to .build/design-gallery, without taking focus.
gallery-shots:
	./scripts/design/gallery-shots.sh

# Opens the Debug app and fails when it is busy while idle (a SwiftUI update loop).
smoke-idle:
	./scripts/smoke-idle.sh

diagnostics-export:
	./scripts/diagnostics-export.sh

# Debug build that loops the notch through every state.
overlay-demo:
	./scripts/run-debug.sh -overlayDemo YES

install:
	./scripts/install.sh

# Developer ID build, notarization, appcast and GitHub release; NOTES=<file> adds release notes.
release:
	./scripts/release.sh $(NOTES)

# Builds two releases under a test bundle ID and proves Sparkle updates one to the other.
# Needs the Developer ID certificate, so it stays out of make check.
update-e2e:
	./scripts/release/update-e2e.sh

DEVICE ?= default
RUNS ?= 20
MODE ?= cold
export DEVICE RUNS MODE

capture-latency:
	./scripts/latency/capture-latency.sh --device "$$DEVICE" --runs "$$RUNS" --mode "$$MODE"

device-change:
	./scripts/latency/capture-latency.sh --device-change

device-change-bluetooth:
	./scripts/latency/capture-latency.sh --device-change --bluetooth --runs "$$RUNS"

speech-check-bluetooth:
	./scripts/latency/capture-latency.sh --speech-check $${RUNS:+--runs "$$RUNS"}

dictation-latency:
	./scripts/latency/dictation-latency.sh --runs "$$RUNS"

# Plays a WAV fixture through the real pipeline, model and overlay, and checks the text,
# LB-01 and LB-02. No microphone, key press or paste. HARNESS_RUNS is 1 to 10. MODEL is a model
# id or all; without it the active model plays.
dictation-harness:
	./scripts/latency/dictation-harness.sh --runs $${HARNESS_RUNS:-5} --fixture $${FIXTURE:-en-short} \
	  $${MODEL:+--model "$$MODEL"}

ROWS ?= 50000
transcripts-latency:
	./scripts/latency/transcripts-latency.sh --rows "$(ROWS)"

# Release-to-text latency per local model and strategy (scripts/latency/model-bench/README.md).
# Empty MODELS, STRATEGIES or FIXTURES means every installed model, every registered strategy and
# the standard fixtures. RUNS is the run count for fixtures under 10 s; longer ones get half.
MODELS ?=
STRATEGIES ?=
FIXTURES ?=
model-bench: whisper
	swift run -c release --package-path scripts/latency/model-bench model-bench --runs "$(RUNS)" \
	  $(if $(MODELS),--models "$(MODELS)") $(if $(STRATEGIES),--strategies "$(STRATEGIES)") \
	  $(if $(FIXTURES),--fixtures "$(FIXTURES)")

# A fast check while iterating: Whisper shipping at the settled pace. Compare final numbers with
# model-bench at the default realtime pace.
model-bench-quick: whisper
	swift run -c release --package-path scripts/latency/model-bench model-bench --models whisperTurbo \
	  --strategies shipping --fixtures en-short,en-long --runs 3 --long-runs 3 --pace settled

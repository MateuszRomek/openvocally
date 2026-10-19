# Domain docs

OpenVocally keeps no glossary file and no architecture decision records. `docs/architecture.md` describes the modules, the dictation pipeline and the design decisions worth knowing. `docs/design.md` and `docs/latency-budgets.md` hold the design system and the latency budgets.

Agent skills that look for `CONTEXT.md` or `docs/adr/` should read those three files instead, and should not create `CONTEXT.md` or `docs/adr/`. When a change settles a decision worth keeping, update `docs/architecture.md` in the same pull request and put the reasoning in the pull request description.

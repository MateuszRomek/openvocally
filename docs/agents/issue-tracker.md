# Issue tracker: GitHub

OpenVocally's issues live in GitHub Issues for `MateuszRomek/openvocally`. Agent skills use the `gh` CLI for every operation. Pass `--repo MateuszRomek/openvocally` so a command works from a fork or a worktree too.

## Commands

- **Create an issue**: `gh issue create --repo MateuszRomek/openvocally --title "..." --body "..."`. Use a heredoc for a multi-line body.
- **Read an issue**: `gh issue view <number> --repo MateuszRomek/openvocally --json title,body,comments,labels`.
- **List issues**: `gh issue list --repo MateuszRomek/openvocally --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`, with `--label` and `--state` filters as needed.
- **Comment on an issue**: `gh issue comment <number> --repo MateuszRomek/openvocally --body "..."`
- **Add or remove labels**: `gh issue edit <number> --repo MateuszRomek/openvocally --add-label "..."` or `--remove-label "..."`
- **Close**: `gh issue close <number> --repo MateuszRomek/openvocally --comment "..."`

## Pull requests

The `triage` skill handles issues only. Pull requests are not accepted for now.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --repo MateuszRomek/openvocally --json title,body,comments,labels`.

# Scope sketches

Pick the one view that makes the change obvious. Use two only when each answers a different reviewer question. Adapted from the `pr` skill in [Matt Pocock's skills](https://github.com/mattpocock/skills).

| The change is about | Sketch |
| --- | --- |
| Logic or an algorithm | Pseudocode |
| Runtime control flow | Call tree |
| UI structure | Component tree, with the state and package boundaries that matter |
| File responsibility or a broad refactor | Shallow file tree with one-line roles |
| Interaction between components or data flow | Mermaid `sequenceDiagram` or `flowchart` |
| A change to an existing shape | `diff` of that shape |

Prefer a `diff` sketch when the surrounding shape already exists. Match the diff to the topic, not to the source files:

```diff
 submitForm
   createSession
     persistPrompt
+    expandSkillMention
     launchAgent
```

```diff
 src/
 ├── commands/
+│   └── expand.ts        # expands the slash command
-└── transport.ts
+└── transport/
+    ├── client.ts
+    └── stream.ts
```

Show a whole block instead of a diff when most of it is new, when an omitted line would hide ownership or order, or when the reviewer needs the target shape to copy.

Keep each sketch under about 12 lines. Use the domain terms from `CONTEXT.md` when the repository has one.

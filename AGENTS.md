# Agent instructions

## Enforced rules (checks, not advice)

These follow three rules from Lauren Tan (Grok Bot): ban what agents misuse, review the proof rather than the diff, and turn every correction into a check.

1. **Banned patterns are in `tools/agent-guard/agent-guard.config.json`.** Run `node tools/agent-guard/agent-guard.mjs` before you push. Existing violations are baselined, and the count may go down but never up. If you remove some, run it with `--update`.
2. **Every PR carries proof.** Run the app or script yourself and put screenshots, a recording, or command output under `## Proof` in the PR body. CI rejects PRs without it.
3. **A correction becomes a check, not a sentence here.** When an agent gets something wrong, add a rule to `agent-guard.config.json` (or a lint rule, a type, or a test) in the same PR as the fix. Don't add more prose to this file.
4. **No comments that justify a workaround.** Fix the cause. The next agent will copy a hack that has a comment explaining why it's fine.

---
name: annotate-last
description: Open Claude's last reply in the Annotator app so the user can mark it up, then revise it from their feedback.
disable-model-invocation: true
allowed-tools: Bash(annotator *)
---

The user wants to correct your previous reply by hand. It will open in the Annotator app, where they strike out, replace, insert and comment on the text, and their feedback comes back to you.

## 1. Open the reply for review

Run this with the Bash tool, with `run_in_background: true` and `timeout: 7200000`:

```
annotator last-reply --session ${CLAUDE_SESSION_ID}
```

A review takes as long as the user needs, which can be longer than a foreground command may run, so it has to run in the background. Then end your turn with one short line saying the reply is open in Annotator. Do not poll or wait in a loop: you are notified when the command finishes.

## 2. Act on what comes back

When the command finishes, read its output.

- **It starts with `## Feedback`.** These are the user's corrections to your previous reply. Each numbered item quotes the exact text it refers to; "Which one" lines tell repeated phrases apart; "Keep as is" lists text that must not change; "General" applies to the whole reply. Write a revised version of that reply which applies every item, and present it. Do not defend the original wording, and do not change anything the feedback did not ask to change.
- **It says the review was cancelled, or that Annotator could not be reached.** Say so in one line and carry on. Do not retry.

If the background command was stopped before it finished (for example at its time limit), the review may still have been completed. Run `annotator result --session ${CLAUDE_SESSION_ID}` once to collect it.

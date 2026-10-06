---
name: annotate-last
description: Open Claude's last reply in the Annotator app so the user can mark it up, then act on their feedback.
disable-model-invocation: true
allowed-tools: Bash(annotator *)
---

The user wants to go through your previous reply by hand. It will open in the Annotator app, where they strike out, replace, insert and comment on the text, and their feedback comes back to you. They may be correcting the reply, or answering it: saying which of its suggestions to act on, asking about one, or adding something.

## 1. Open the reply for review

Run this with the Bash tool, with `run_in_background: true` and `timeout: 7200000`:

```
annotator last-reply --session ${CLAUDE_SESSION_ID}
```

A review takes as long as the user needs, which can be longer than a foreground command may run, so it has to run in the background. Then end your turn with one short line saying the reply is open in Annotator. Do not poll or wait in a loop: you are notified when the command finishes.

## 2. Act on what comes back

When the command finishes, read its output.

- **It starts with `## Feedback`.** This is the user's response to your previous reply, item by item. Each numbered item quotes the exact text it refers to; "Expand" asks for more on the quoted passage and "Summarize" for the same in fewer words; "Which one" lines tell repeated phrases apart; "Keep as is" lists text that must not change; "General" applies to the whole reply.

  Read each item for what it asks of you:
  - A deletion, replacement or insertion that edits the wording is a correction. Apply it.
  - A comment or an inserted note may instead be an instruction ("yes, do this"), a question, or something new the user is telling you. Carry out the instruction, answer the question, take up the new point.

  Then reply with what you did about every item. Write out a revised version of the reply only when the feedback corrects its text; when the user was answering the reply, do the work it asks for instead of rewriting the reply. Do not defend the original wording, and do not change anything the feedback did not ask to change.
- **It says a sandbox blocks the socket** (exit status 77). The app is running, but this command was not allowed to talk to it, so nothing was opened. Run the same command once more with the sandbox disabled for it, again in the background with the same timeout; the user may be asked to allow that. If that is refused or not possible, tell the user in two lines: the review could not open because the sandbox blocks Annotator's socket, and the setting the message names lifts it for good. Do not try anything else.
- **It says the review was cancelled, or that Annotator could not be reached.** Say so in one line and carry on. Do not retry.

If the background command was stopped before it finished (for example at its time limit), the review may still have been completed. Run `annotator result --session ${CLAUDE_SESSION_ID}` once to collect it.

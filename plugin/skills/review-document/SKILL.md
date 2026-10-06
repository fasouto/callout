---
name: review-document
description: Open a finished document in the Annotator app so the user can mark it up before it goes out. Use right after generating or substantially rewriting a document the user will send to someone else (a CV, cover letter, proposal, blog post, long email or message), or when the user asks to review, annotate or mark up a document. Not for code, plans, short answers or chat replies.
allowed-tools: Bash(annotator *)
---

The user corrects documents by hand in the Annotator app: they strike out, replace, insert and comment on the text, the way a teacher marks up an essay. Your job is to hand the document over, wait, and then act on what comes back.

## 1. Choose what to open

- If you generated a PDF, open the PDF: it is what the reader will see.
- Otherwise open the source file itself (markdown, HTML, plain text).

Remember which **source** the document is generated from (the markdown, HTML or LaTeX file, or the script that builds it). Feedback is always applied to the source, never to a PDF.

## 2. Open it and wait

Run this with the Bash tool, with `run_in_background: true` and `timeout: 7200000`:

```
annotator review "<absolute path to the file>" --session ${CLAUDE_SESSION_ID}
```

A review takes as long as the user needs, which can be longer than a foreground command may run, so it has to run in the background. Then end your turn with one short line saying the document is open in Annotator. Do not poll or wait in a loop: you are notified when the command finishes.

## 3. Act on what comes back

When the command finishes, read its output.

- **It starts with `## Feedback`.** Each numbered item quotes the exact text it refers to, with a page number for a PDF. The quote is how you find the place in the source: search the source for it. "Expand" asks for more on the quoted passage and "Summarize" for the same in fewer words; "Which one" lines tell repeated phrases apart; "Keep as is" lists text that must not change; "General" applies to the whole document. Apply every item to the source, change nothing else, then regenerate the output if there is one (the PDF, for example). A comment that asks you something instead of asking for a change is a question: leave that text as it is and answer it. Finish with a short summary of what changed, item by item, with the answers to any questions.
- **It is the document's full text, with no `## Feedback` heading.** The user edited the text directly. Write exactly this text to the source file, then regenerate the output if there is one.
- **It says the document was approved.** Nothing to change.
- **It says the review was cancelled, or that Annotator could not be reached.** Say so in one line and carry on without a review. Do not retry.

If the background command was stopped before it finished (for example at its time limit), the review may still have been completed. Run `annotator result --session ${CLAUDE_SESSION_ID}` once to collect it.

Do not open another review after applying the feedback unless the user asks for one.

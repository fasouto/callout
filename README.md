# Annotator

A native macOS menu-bar app for correcting AI-written text the way a teacher marks up an essay: strike out, replace, insert, comment, mark as good. The result goes back to the AI as structured feedback, or to you as the corrected text.

It has two parts:

- **The app** shows the text or PDF, lets you annotate it, and returns the result.
- **A Claude Code plugin** hands plans, replies and generated documents to the app and returns your feedback to Claude.

Status: early development. The core library (capture contract, marks, feedback formatter, apply-edits, markdown source mapping) is in place and tested. The app, the `annotator` command-line tool and the plugin are next.

## Building

Requirements: macOS 14 or later, Apple Silicon.

### Core library

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```sh
cd Packages/AnnotatorKit
swift build
swift test
```

### App

Not buildable yet. It will need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen); instructions will be added here with the first app milestone.

## Layout

```
Packages/AnnotatorKit/   Swift package with everything that is not UI
  Sources/AnnotatorCore/ contract, marks, formatter, apply-edits, markdown source mapping
```

## License

GPLv3. See [LICENSE](LICENSE).

import Testing

/// The tests here run one at a time. They share the main thread, its queue and
/// AppKit's focus: side by side, one test's queued focus change lands in the
/// middle of another while the first one waits.
@Suite(.serialized)
enum OnTheMainThread {}

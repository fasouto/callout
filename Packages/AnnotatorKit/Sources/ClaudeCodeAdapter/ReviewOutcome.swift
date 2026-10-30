/// What the command-line tool prints when a review ends without feedback.
///
/// The tool prints these and the transcript reader recognises them, so they are
/// defined once: Claude's one-line reply to such an output is noise when
/// counting replies back, and the reader finds it by these phrases.
public enum ReviewOutcome {
    public static let cancelled = "The review was cancelled. No feedback was given."
    public static let closed = "Annotator closed before the review was finished, so no feedback was given."
    public static let unreachable = "Annotator could not be reached, so no review was done."

    static let withoutFeedback = [cancelled, closed, unreachable]
}

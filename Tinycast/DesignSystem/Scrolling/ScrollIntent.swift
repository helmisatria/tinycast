import Foundation

/// A scroll request; reset and follow need different ops, so the caller states which.
struct ScrollIntent: Equatable {
    enum Kind {
        case top
        /// Keyboard nav: minimal scroll-to-visible, leaving a visible row where it is.
        case follow
        /// Landing past the first row: centre it, so the rows above it stay in view.
        case center
    }

    var kind: Kind
    /// Distinguishes back-to-back intents of the same kind so `onChange` still fires.
    var nonce = UUID()
}

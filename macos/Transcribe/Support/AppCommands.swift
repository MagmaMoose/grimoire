import SwiftUI

/// A bridge from the menu bar's commands to the window that acts on them.
///
/// `.commands` is attached to the Scene, so it cannot reach a view's `@State`.
/// Rather than scatter `@FocusedValue` through the view tree for four menu
/// items, the command raises a request here and the window observes it.
@MainActor
@Observable
final class AppCommands {
    enum Destination: Equatable {
        case meetings
        case actions
        case queue
    }

    /// Carries a token so the same destination twice in a row still fires.
    ///
    /// Writing nil and then the value in one synchronous scope does not work:
    /// `onChange` compares against the value at the next body evaluation, by
    /// which time both writes have landed and it sees no change.
    struct Request: Equatable {
        let token: Int
        let destination: Destination
    }

    private(set) var refreshToken = 0
    private(set) var request: Request?
    private var nextToken = 0

    func refresh() { refreshToken += 1 }

    func show(_ destination: Destination) {
        nextToken += 1
        request = Request(token: nextToken, destination: destination)
    }
}

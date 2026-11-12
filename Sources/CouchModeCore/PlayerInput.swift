// Owns: what an input intent means while a streaming site is on screen.
// The answer is a key to press in the page (a real key event, so the site's
// own player handles it), or a shell-level action.

public enum Key: Equatable, Sendable {
    case up, down, left, right, enter, space, escape
}

public enum PlayerCommand: Equatable, Sendable {
    case press(Key)
    case goBackInPage
    case returnHome
}

public enum PlayerInput {
    public static func command(for intent: ShellIntent, service: Service) -> PlayerCommand {
        switch intent {
        case .home:
            return .returnHome
        case .move(let d):
            return .press(key(for: d))
        case .select:
            // Enter; our in-page script turns Enter into play/pause during playback.
            return .press(.enter)
        case .info:
            // The remote's Play/Pause: play/pause in the site's player.
            return .press(.space)
        case .back:
            // TV interfaces (YouTube /tv) treat Escape as their own Back.
            // Regular sites go back one page; the shell returns home when
            // there is no page left to go back to.
            return service.hasTVInterface ? .press(.escape) : .goBackInPage
        }
    }

    private static func key(for d: Direction) -> Key {
        switch d {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}

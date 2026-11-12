// Owns: the device-independent vocabulary of user input. Keyboard and game
// controllers both translate into these; nothing downstream knows which it was.

public enum Direction: Equatable, Sendable {
    case up, down, left, right
}

public enum ShellIntent: Equatable, Sendable {
    case move(Direction)
    case select      // A / Return
    case back        // B / Escape
    case home        // Menu button / ⌘⌫: always returns to the home screen
    case info        // Play/Pause (remote), Y (controller), I (keyboard): details; play/pause on sites
}

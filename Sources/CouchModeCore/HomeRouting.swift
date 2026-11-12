// Owns: what Home does, given the app in front and the button that asked,
// and where a game controller's presses go (ControllerRouting, at the end).
// Apple TV rule: Home always ends at the shell, and the app in front steps
// aside in the way that keeps the player's place. A streaming app closes
// (its service remembers the position). A retro game saves its state and
// quits (it reopens there). A Switch game pauses in the background (Play
// resumes it). Buttons a game uses itself stay the game's.

/// The kind of app in front when Home is pressed.
public enum FrontApp: Equatable, Sendable {
    case shell
    /// A service's own Mac app the shell opens, such as Plex HTPC.
    case streamingApp
    case retroArch
    /// A Switch game (an NX2Apple Mac app from the games folder).
    case switchGame
    /// Anything else: System Settings, Finder, a stray window.
    case other
}

/// Which button asked for Home.
public enum HomeSource: String, Equatable, Sendable, CaseIterable {
    /// The Siri Remote's TV button, its Back button held, ⌘⌫ or the Home key.
    case remoteOrKeyboard = "remote"
    /// A game controller's Home (logo) button.
    case controllerHome = "controller"
    /// A game controller's Menu button (+, Start, Options) held.
    case controllerMenuHold = "menu"
}

public enum HomeStep: Equatable, Sendable {
    /// The shell is in front: its own Home.
    case shellHome
    /// Quit the app, then show the shell.
    case closeApp
    /// Save a state and quit RetroArch; the shell returns when it exits.
    case saveAndQuitRetroArch
    /// Pause the Switch game in the background, then show the shell.
    case pauseGame
    /// Hide the app in front, then show the shell.
    case hideApp
    /// The game uses this button itself: do nothing.
    case leaveToGame
}

public enum HomeRouting {
    public static func step(front: FrontApp, source: HomeSource) -> HomeStep {
        switch (front, source) {
        case (.shell, _): return .shellHome
        case (.streamingApp, _): return .closeApp
        // Start is a game button; Start + Select is RetroArch's own quit.
        case (.retroArch, .controllerMenuHold): return .leaveToGame
        case (.retroArch, _): return .saveAndQuitRetroArch
        case (.switchGame, .remoteOrKeyboard): return .pauseGame
        // The game opens its own Home menu (Resume, Quit, Back to console
        // mode) for the controller's Home button, and + is a game button.
        case (.switchGame, _): return .leaveToGame
        case (.other, _): return .hideApp
        }
    }
}

/// Where a game controller's presses go, given the app in front. Games read
/// controllers themselves; any other app (Plex HTPC, System Settings) gets
/// them as keys, the way the Siri Remote drives it.
public enum ControllerTarget: Equatable, Sendable {
    case shell
    /// Arrow keys, Return, Esc and Space in the app in front.
    case appAsKeys
    /// Nothing: the game in front reads the controller.
    case game
}

public enum ControllerRouting {
    public static func target(shellActive: Bool, front: FrontApp) -> ControllerTarget {
        if shellActive { return .shell }
        switch front {
        case .shell: return .shell
        case .retroArch, .switchGame: return .game
        case .streamingApp, .other: return .appAsKeys
        }
    }
}

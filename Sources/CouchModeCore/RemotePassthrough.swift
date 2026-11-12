// Owns: what an Apple TV remote press becomes when another app (Plex HTPC,
// RetroArch, a Switch game) is in front: the keyboard key that app already
// understands. Home never passes through; it always returns to the shell.

public enum RemotePassthrough {
    public static func key(for intent: ShellIntent) -> Key? {
        switch intent {
        case .move(.up): return .up
        case .move(.down): return .down
        case .move(.left): return .left
        case .move(.right): return .right
        case .select: return .enter
        case .back: return .escape
        case .info: return .space        // the remote's Play/Pause
        case .home: return nil
        }
    }
}

// Owns: the "Netflix 5.1 audio" setting as pure logic: its three values, the
// decision (setting x output channel count -> effective on/off), how the
// output is described in Settings, and the page script Netflix gets when the
// effective value is on. The script only widens the list of audio formats the
// Netflix web player asks for; licenses, keys and the CDM are untouched.

import Foundation

public enum Netflix51: String, CaseIterable, Sendable {
    case auto, on, off

    /// Output channels needed for Auto to turn 5.1 on.
    public static let minChannels = 6

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// The saved value, or Auto when absent or unknown.
    public init(stored: String?) { self = stored.flatMap(Netflix51.init(rawValue:)) ?? .auto }

    /// Whether Netflix is asked for 5.1. Auto follows the output's channel count (nil = unknown = off).
    public func effective(channels: Int?) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .auto: return (channels ?? 0) >= Netflix51.minChannels
        }
    }

    /// Settings value text, e.g. "Auto (off)" so it is clear what Auto decided.
    public func summary(channels: Int?) -> String {
        self == .auto ? "Auto (\(effective(channels: channels) ? "on" : "off"))" : label
    }

    /// "Mac mini Speakers \u{00B7} 2 channels".
    public static func describeOutput(name: String, channels: Int?) -> String {
        guard let channels, channels > 0 else { return name }
        return "\(name) \u{00B7} \(channels) \(channels == 1 ? "channel" : "channels")"
    }

    /// The script a service's pages get for this feature: Netflix only, and only when effective-on.
    public static func script(forService id: String, enabled: Bool) -> String? {
        id == "netflix" && enabled ? source : nil
    }

    /// Adds `ddplus-5.1-dash` to the audio profiles in Netflix's manifest request. Wrapped in
    /// try/catch at every level: if the hook fails, the request goes out unchanged and Netflix stays stereo.
    public static let source = #"""
    try {
      (function () {
        if (globalThis.__cmNetflix51) return;
        globalThis.__cmNetflix51 = true;
        var EXTRA = ['ddplus-5.1-dash'];
        var orig = JSON.stringify;
        JSON.stringify = function (value) {
          try {
            var p = value && value.params;
            if (p && Array.isArray(p.profiles) && p.type === 'standard') {
              EXTRA.forEach(function (x) { if (p.profiles.indexOf(x) < 0) p.profiles.push(x); });
              globalThis.__cmNetflix51Hits = (globalThis.__cmNetflix51Hits || 0) + 1;
            }
          } catch (e) {}
          return orig.apply(this, arguments);
        };
      })();
    } catch (e) {}
    """#
}

// Owns: how far a TV row slides so its focused item stays in view (tvOS
// style: after the first card, the focused one sits in the second slot).

import CoreGraphics

public enum RowSlide {
    public static func offset(focusedColumn: Int, step: CGFloat) -> CGFloat {
        CGFloat(max(0, focusedColumn - 1)) * step
    }
}

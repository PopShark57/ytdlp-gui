import Foundation

extension Comparable {
    /// Constrains the value to `range`.
    ///
    /// Named `constrained` rather than the more obvious `clamped` because the standard library
    /// already declares a package-level `clamped(to:)`, which would shadow this one.
    func constrained(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

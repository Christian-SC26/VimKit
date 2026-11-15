import VimCore

extension Array where Element == VimFold {
    /// Folds whose header line ends inside `lower...upper` (character offsets).
    /// `VimEngine.folds` is sorted, so this is a binary search plus the run
    /// of matches: fold labels are only placed near the visible text.
    func withHeaders(between lower: Int, and upper: Int) -> ArraySlice<VimFold> {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].hiddenRange.location - 1 < lower { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < count, self[end].hiddenRange.location - 1 <= upper { end += 1 }
        return self[low..<end]
    }
}

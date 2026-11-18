import Foundation

/// Where the search terms match inside a string, for highlighting in the quick-connect list.
package enum SearchHighlight {
    /// Ranges (in `text`) matched by any whitespace-separated term of `query`, case- and
    /// diacritic-insensitive, sorted and merged where they overlap or touch.
    package static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [Range<String.Index>] = []
        for term in terms {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: cursor..<text.endIndex) {
                found.append(range)
                cursor = range.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The first letter of a host name for the avatar, uppercased; "#" for an empty name.
    package static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
    }
}

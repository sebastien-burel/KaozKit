import Foundation

/// Routes inline `<think>…</think>` spans out of a text stream. Models that
/// reason without a `reasoning_content` field (MiniMax, DeepSeek-R1
/// distills behind a generic server, Gemma via a gateway) put their chain
/// of thought in `content` itself; without this it lands in the answer.
///
/// Streaming-aware: a marker can arrive split across deltas, so the tail
/// of the buffer that could still start one is held back until the next
/// delta settles it. `flush()` releases whatever is left at end of stream.
struct ThinkTagFilter {
    private static let open = "<think>"
    private static let close = "</think>"

    private var pending = ""
    private var inThink = false
    /// Skip the whitespace models put right after a marker, so the answer
    /// doesn't start with the blank line that separated it from the thought.
    private var trimLeading = false

    struct Output: Equatable {
        var text = ""
        var reasoning = ""
    }

    mutating func feed(_ delta: String) -> Output {
        pending += delta
        var out = Output()
        while true {
            let marker = inThink ? Self.close : Self.open
            if let range = pending.range(of: marker) {
                emit(String(pending[..<range.lowerBound]), into: &out)
                pending = String(pending[range.upperBound...])
                inThink.toggle()
                trimLeading = true
                continue
            }
            // Hold back a tail that could be the start of the marker.
            let keep = Self.partialMarkerSuffix(of: pending, marker: marker)
            emit(String(pending.dropLast(keep)), into: &out)
            pending = String(pending.suffix(keep))
            return out
        }
    }

    mutating func flush() -> Output {
        var out = Output()
        emit(pending, into: &out)
        pending = ""
        return out
    }

    private mutating func emit(_ chunk: String, into out: inout Output) {
        var chunk = Substring(chunk)
        if trimLeading {
            chunk = chunk.drop(while: \.isWhitespace)
            if chunk.isEmpty { return }
            trimLeading = false
        }
        if inThink { out.reasoning += chunk } else { out.text += chunk }
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `marker`.
    private static func partialMarkerSuffix(of s: String, marker: String) -> Int {
        let max = min(s.count, marker.count - 1)
        guard max > 0 else { return 0 }
        for length in stride(from: max, through: 1, by: -1) where s.hasSuffix(marker.prefix(length)) {
            return length
        }
        return 0
    }
}

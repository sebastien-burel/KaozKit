import Foundation

/// What a manifest keeps of a JSON answer: the fields its `keep` paths name,
/// the rest dropped — a search's titles, addresses and snippets, not the
/// tens of kilobytes around them.
enum PluginResponse {
    /// `body` reduced to `paths` (`web.results.title`: an array on the way
    /// is gone through, each element kept the same). Nil when the body is
    /// not JSON or no path matches: the answer is then given whole.
    static func keeping(_ paths: [String], of body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
        let tree = paths.reduce(into: Tree()) { tree, path in
            tree.insert(path.split(separator: ".").map(String.init))
        }
        guard let kept = prune(root, tree), !isEmpty(kept),
              let data = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private struct Tree {
        var children: [String: Tree] = [:]

        mutating func insert(_ path: [String]) {
            guard let first = path.first else { return }
            children[first, default: Tree()].insert(Array(path.dropFirst()))
        }
    }

    private static func prune(_ value: Any, _ tree: Tree) -> Any? {
        if tree.children.isEmpty { return value }
        if let array = value as? [Any] { return array.compactMap { prune($0, tree) } }
        guard let object = value as? [String: Any] else { return nil }
        var kept: [String: Any] = [:]
        for (key, sub) in tree.children {
            if let child = object[key], let pruned = prune(child, sub) { kept[key] = pruned }
        }
        return kept.isEmpty ? nil : kept
    }

    private static func isEmpty(_ value: Any) -> Bool {
        (value as? [Any])?.allSatisfy(isEmpty) ?? (value as? [String: Any])?.isEmpty ?? false
    }
}

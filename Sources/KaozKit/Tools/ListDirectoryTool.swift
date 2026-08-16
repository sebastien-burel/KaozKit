import Foundation

/// Lists the entries of a directory inside one of the user's authorised
/// folders. Called with no path it enumerates the authorised roots themselves,
/// letting the model discover where it's allowed to look.
public struct ListDirectoryTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    public let spec = ToolSpec(
        name: "list_directory",
        description: """
        Lists files and subfolders inside one of the user's authorised local
        folders. Call without a path to discover the authorised root folders
        and their absolute paths; then call with an absolute path to inspect a
        directory. Set recursive to true to get the whole subtree in one call
        (names are relative to the listed directory) instead of having to
        descend folder by folder. Read-only.

        Returns JSON. With no path: {"roots":[{"name","path"}]}. With a path:
        {"path","entries":[{"name","type":"file"|"directory","bytes"}],
        "truncated"}. Every name is a real filename read from disk: quote them
        exactly as given. Never translate, rename, correct or infer a filename,
        and never describe a file that is not in entries — if a name looks
        unclear or unexpected, report it as-is and say so.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Absolute path of the directory to list. Omit to list the authorised roots."
            },
            "recursive": {
              "type": "boolean",
              "description": "List the full subtree in one call (default false)."
            }
          },
          "additionalProperties": false
        }
        """
    )

    private static let maxEntries = 1000

    private struct Args: Decodable {
        let path: String?
        let recursive: Bool?
    }

    public func execute(arguments: Data) async throws -> String {
        let args = (try? JSONDecoder().decode(Args.self, from: arguments))
            ?? Args(path: nil, recursive: nil)

        guard let path = args.path, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return listRoots()
        }

        return try FileSpaceAccess.withScopedAccess(to: path, roots: roots) { url in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ToolError.execution(message: "introuvable : \(path)")
            }
            guard isDir.boolValue else {
                throw ToolError.execution(message: "n'est pas un dossier : \(path)")
            }
            return args.recursive == true
                ? Self.listRecursive(url, fm: fm)
                : try Self.listShallow(url, fm: fm)
        }
    }

    /// Serialises to JSON rather than a hand-rolled table. A model copying a
    /// filename out of `name\t123 o` has nothing marking it as data to quote
    /// verbatim, and one was observed inventing plausible French invoice names
    /// for entries it did not recognise while keeping their exact sizes — the
    /// correct figures made the fabricated names look trustworthy. JSON gives
    /// each name its own labelled field, and lets the type be stated instead of
    /// implied by a trailing slash.
    private static func json(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return #"{"error":"could not encode listing"}"# }
        return text
    }

    private static func entry(name: String, values: URLResourceValues?) -> [String: Any] {
        if values?.isDirectory == true {
            return ["name": name, "type": "directory"]
        }
        return ["name": name, "type": "file", "bytes": values?.fileSize ?? 0]
    }

    private static func listShallow(_ url: URL, fm: FileManager) throws -> String {
        let entries = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let listed = entries
            .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maxEntries)
            .map { url -> [String: Any] in
                entry(name: url.lastPathComponent,
                      values: try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]))
            }
        return json([
            "path": url.path,
            "entries": Array(listed),
            "truncated": entries.count > maxEntries,
        ])
    }

    /// Walks the subtree once and returns paths relative to `base`, so the
    /// model sees the whole structure without descending folder by folder.
    private static func listRecursive(_ base: URL, fm: FileManager) -> String {
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "(dossier vide)" }

        let basePath = base.path
        var listed: [[String: Any]] = []
        var truncated = false
        for case let url as URL in enumerator {
            if listed.count >= maxEntries { truncated = true; break }
            var relative = url.path
            if relative.hasPrefix(basePath) {
                relative = String(relative.dropFirst(basePath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            listed.append(entry(
                name: relative,
                values: try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])))
        }
        listed.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return json([
            "path": basePath,
            "entries": listed,
            "truncated": truncated,
        ])
    }

    private func listRoots() -> String {
        var payload: [String: Any] = [
            "roots": roots.map { ["name": $0.name, "path": $0.url.path] },
        ]
        // Keep the actionable hint the plain-text version carried: with no root
        // the model would otherwise just see an empty list and guess.
        if roots.isEmpty {
            payload["note"] = "No folder is authorised yet. The user can add one in settings."
        }
        return Self.json(payload)
    }
}

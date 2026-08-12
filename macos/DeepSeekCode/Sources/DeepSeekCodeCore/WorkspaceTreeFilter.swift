import Foundation

public enum WorkspaceTreeFilter {
    public static func filter(nodes: [WorkspaceFileNode], query: String) -> [WorkspaceFileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nodes }

        let lowered = trimmed.lowercased()
        let matchingPaths = Set(nodes.filter { node in
            node.path.lowercased().contains(lowered) || node.name.lowercased().contains(lowered)
        }.map(\.path))
        guard !matchingPaths.isEmpty else { return [] }

        return nodes.filter { node in
            if matchingPaths.contains(node.path) { return true }
            if matchingPaths.contains(where: { $0.hasPrefix(node.path + "/") }) { return true }
            return ancestorPaths(for: node.path).contains(where: { matchingPaths.contains($0) })
        }
    }

    private static func ancestorPaths(for path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        var ancestors: [String] = []
        for upperBound in parts.indices.dropLast() {
            ancestors.append(parts[0...upperBound].joined(separator: "/"))
        }
        return ancestors
    }
}

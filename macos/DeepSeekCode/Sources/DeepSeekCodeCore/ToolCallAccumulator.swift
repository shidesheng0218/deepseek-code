import Foundation

public struct IncrementalToolCall: Codable, Equatable, Sendable {
    public let index: Int
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(index: Int, id: String, name: String, argumentsJSON: String) {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct IncrementalToolCallAccumulator: Sendable {
    private struct Partial: Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: Partial] = [:]
    private var emitted: Set<Int> = []

    public init() {}

    public mutating func append(index: Int, id: String?, name: String?, arguments: String?) {
        var partial = partials[index, default: Partial()]
        if let id, !id.isEmpty { partial.id += id }
        if let name, !name.isEmpty { partial.name += name }
        if let arguments, !arguments.isEmpty { partial.arguments += arguments }
        partials[index] = partial
    }

    public mutating func completedCalls() -> [IncrementalToolCall] {
        let calls = partials.compactMap { index, partial -> IncrementalToolCall? in
            guard !emitted.contains(index), !partial.id.isEmpty, !partial.name.isEmpty, isJSONObject(partial.arguments) else { return nil }
            return IncrementalToolCall(index: index, id: partial.id, name: partial.name, argumentsJSON: partial.arguments)
        }.sorted { $0.index < $1.index }
        emitted.formUnion(calls.map(\.index))
        return calls
    }

    public mutating func reset() {
        partials.removeAll(keepingCapacity: true)
        emitted.removeAll(keepingCapacity: true)
    }

    private func isJSONObject(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }
}

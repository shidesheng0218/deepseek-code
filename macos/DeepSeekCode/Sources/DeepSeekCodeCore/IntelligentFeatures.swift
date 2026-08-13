import Foundation

/// 编译错误自动修复器
public class CompileErrorFixer {
    private let workspace: WorkspaceStore

    public init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    /// 自动修复编译错误
    public func autoFix(errors: [CompileError], sessionID: String) async throws {
        for error in errors {
            if let quickFix = tryQuickFix(error) {
                try await applyFix(quickFix, sessionID: sessionID)
            } else {
                try await askAIToFix(error, sessionID: sessionID)
            }
        }
    }

    /// 尝试快速修复
    private func tryQuickFix(_ error: CompileError) -> QuickFix? {
        switch error.type {
        case .missingImport:
            if let module = error.suggestedModule {
                return .addImport(moduleName: module, file: error.file)
            }

        case .typo:
            if let suggestion = error.suggestion {
                return .replace(file: error.file, range: error.range, with: suggestion)
            }

        case .missingReturn:
            if let function = error.function {
                return .addReturn(file: error.file, function: function)
            }

        case .unusedVariable:
            if let varName = error.variableName {
                return .prefixWithUnderscore(file: error.file, range: error.range, varName: varName)
            }

        case .typeInference:
            if let explicitType = error.suggestedType {
                return .addTypeAnnotation(file: error.file, range: error.range, type: explicitType)
            }

        default:
            return nil
        }

        return nil
    }

    /// 应用快速修复
    private func applyFix(_ fix: QuickFix, sessionID: String) async throws {
        switch fix {
        case .addImport(let moduleName, let file):
            // 读取文件
            guard let content = try? String(contentsOfFile: file) else { return }

            // 查找 import 插入位置
            let lines = content.components(separatedBy: .newlines)
            var insertIndex = 0

            for (index, line) in lines.enumerated() {
                if line.hasPrefix("import ") {
                    insertIndex = index + 1
                }
            }

            let newImport = "import \(moduleName)"
            var newLines = lines
            newLines.insert(newImport, at: insertIndex)

            let newContent = newLines.joined(separator: "\n")
            try newContent.write(toFile: file, atomically: true, encoding: .utf8)

        case .replace(let file, let range, let newText):
            guard let content = try? String(contentsOfFile: file) else { return }
            var newContent = content
            if let range = Range(range, in: content) {
                newContent.replaceSubrange(range, with: newText)
                try newContent.write(toFile: file, atomically: true, encoding: .utf8)
            }

        case .addReturn(let file, _):
            // 简化实现：在函数末尾添加 return
            guard (try? String(contentsOfFile: file)) != nil else { return }
            // TODO: 实现完整的 return 语句添加逻辑
            break

        case .prefixWithUnderscore(let file, let range, let varName):
            guard let content = try? String(contentsOfFile: file) else { return }
            var newContent = content
            if let range = Range(range, in: content) {
                newContent.replaceSubrange(range, with: "_\(varName)")
                try newContent.write(toFile: file, atomically: true, encoding: .utf8)
            }

        case .addTypeAnnotation(let file, let range, let type):
            guard let content = try? String(contentsOfFile: file) else { return }
            var newContent = content
            if let range = Range(range, in: content) {
                newContent.replaceSubrange(range, with: "\(content[range]): \(type)")
                try newContent.write(toFile: file, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 请求 AI 修复
    private func askAIToFix(_ error: CompileError, sessionID: String) async throws {
        _ = """
        修复以下编译错误：

        文件: \(error.file)
        行号: \(error.line)
        错误: \(error.message)

        相关代码:
        ```swift
        \(error.contextCode)
        ```

        请直接使用 Edit 工具修改代码，不要解释。
        """

        // TODO: 发送到 AgentHost 处理
    }
}

/// 编译错误模型
public struct CompileError {
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String
    public let type: ErrorType
    public let range: NSRange
    public let contextCode: String
    public let suggestedModule: String?
    public let suggestion: String?
    public let function: String?
    public let variableName: String?
    public let suggestedType: String?

    public init(
        file: String,
        line: Int,
        column: Int,
        message: String,
        type: ErrorType,
        range: NSRange,
        contextCode: String,
        suggestedModule: String? = nil,
        suggestion: String? = nil,
        function: String? = nil,
        variableName: String? = nil,
        suggestedType: String? = nil
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.type = type
        self.range = range
        self.contextCode = contextCode
        self.suggestedModule = suggestedModule
        self.suggestion = suggestion
        self.function = function
        self.variableName = variableName
        self.suggestedType = suggestedType
    }

    public enum ErrorType {
        case missingImport
        case typo
        case missingReturn
        case unusedVariable
        case typeInference
        case typeMismatch
        case undeclaredIdentifier
        case other
    }
}

/// 快速修复类型
enum QuickFix {
    case addImport(moduleName: String, file: String)
    case replace(file: String, range: NSRange, with: String)
    case addReturn(file: String, function: String)
    case prefixWithUnderscore(file: String, range: NSRange, varName: String)
    case addTypeAnnotation(file: String, range: NSRange, type: String)
}

/// 编译错误解析器
public class CompileErrorParser {
    public init() {}

    /// 解析 Swift 编译器输出
    public func parseSwiftCompilerOutput(_ output: String) -> [CompileError] {
        var errors: [CompileError] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            if let error = parseErrorLine(line) {
                errors.append(error)
            }
        }

        return errors
    }

    private func parseErrorLine(_ line: String) -> CompileError? {
        // Swift 错误格式: /path/to/file.swift:10:5: error: message
        let pattern = #"^(.+):(\d+):(\d+):\s+(error|warning):\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        let file = String(line[Range(match.range(at: 1), in: line)!])
        let lineNum = Int(String(line[Range(match.range(at: 2), in: line)!])) ?? 0
        let column = Int(String(line[Range(match.range(at: 3), in: line)!])) ?? 0
        let message = String(line[Range(match.range(at: 5), in: line)!])

        // 检测错误类型
        let errorType = detectErrorType(message)

        // 提取建议
        var suggestion: String?
        var suggestedModule: String?

        if message.contains("did you mean") {
            let suggestionPattern = #"did you mean '([^']+)'"#
            if let suggestionRegex = try? NSRegularExpression(pattern: suggestionPattern),
               let suggestionMatch = suggestionRegex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
                suggestion = String(message[Range(suggestionMatch.range(at: 1), in: message)!])
            }
        }

        if message.contains("no such module") {
            let modulePattern = #"no such module '([^']+)'"#
            if let moduleRegex = try? NSRegularExpression(pattern: modulePattern),
               let moduleMatch = moduleRegex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
                suggestedModule = String(message[Range(moduleMatch.range(at: 1), in: message)!])
            }
        }

        return CompileError(
            file: file,
            line: lineNum,
            column: column,
            message: message,
            type: errorType,
            range: NSRange(location: 0, length: 0), // TODO: 计算实际范围
            contextCode: "", // TODO: 读取上下文代码
            suggestedModule: suggestedModule,
            suggestion: suggestion
        )
    }

    private func detectErrorType(_ message: String) -> CompileError.ErrorType {
        if message.contains("no such module") || message.contains("cannot find") {
            return .missingImport
        } else if message.contains("did you mean") {
            return .typo
        } else if message.contains("missing return") {
            return .missingReturn
        } else if message.contains("never used") || message.contains("unused") {
            return .unusedVariable
        } else if message.contains("type annotation") {
            return .typeInference
        } else if message.contains("cannot convert") || message.contains("type mismatch") {
            return .typeMismatch
        } else if message.contains("cannot find") || message.contains("undeclared") {
            return .undeclaredIdentifier
        } else {
            return .other
        }
    }
}

/// 项目模板管理器
@MainActor
public class ProjectTemplateManager {
    public static let shared = ProjectTemplateManager()

    private init() {}

    public let templates: [CodeTemplate] = [
        CodeTemplate(
            name: "SwiftUI View",
            icon: "square.and.pencil",
            category: "SwiftUI",
            language: "swift",
            code: """
            import SwiftUI

            struct <#Name#>View: View {
                var body: some View {
                    <#content#>
                }
            }

            #Preview {
                <#Name#>View()
            }
            """
        ),
        CodeTemplate(
            name: "SwiftUI ViewModel",
            icon: "gearshape.2",
            category: "SwiftUI",
            language: "swift",
            code: """
            import SwiftUI
            import Combine

            @MainActor
            class <#Name#>ViewModel: ObservableObject {
                @Published var <#property#>: <#Type#>

                init() {
                    // 初始化
                }

                func <#method#>() {
                    // 实现
                }
            }
            """
        ),
        CodeTemplate(
            name: "Network Service",
            icon: "network",
            category: "Networking",
            language: "swift",
            code: """
            import Foundation

            actor <#Name#>Service {
                private let session = URLSession.shared
                private let baseURL = "<#URL#>"

                func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
                    let url = URL(string: baseURL + endpoint)!
                    let (data, response) = try await session.data(from: url)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw NetworkError.invalidResponse
                    }

                    return try JSONDecoder().decode(T.self, from: data)
                }
            }

            enum NetworkError: Error {
                case invalidResponse
                case decodingError
            }
            """
        ),
        CodeTemplate(
            name: "Async Task",
            icon: "arrow.triangle.2.circlepath",
            category: "Concurrency",
            language: "swift",
            code: """
            Task {
                do {
                    let result = try await <#asyncOperation#>()
                    <#handleSuccess#>
                } catch {
                    <#handleError#>
                }
            }
            """
        ),
        CodeTemplate(
            name: "Actor Class",
            icon: "person.2.fill",
            category: "Concurrency",
            language: "swift",
            code: """
            actor <#Name#> {
                private var <#state#>: <#Type#>

                init(<#parameters#>) {
                    <#initialization#>
                }

                func <#method#>() async throws -> <#ReturnType#> {
                    <#implementation#>
                }
            }
            """
        ),
        CodeTemplate(
            name: "Unit Test",
            icon: "checkmark.circle",
            category: "Testing",
            language: "swift",
            code: """
            import XCTest
            @testable import <#ModuleName#>

            final class <#Name#>Tests: XCTestCase {
                func test<#Scenario#>() {
                    // Given
                    <#setup#>

                    // When
                    <#action#>

                    // Then
                    <#assertions#>
                }
            }
            """
        )
    ]

    public func searchTemplates(_ query: String) -> [CodeTemplate] {
        if query.isEmpty {
            return templates
        }

        return templates.filter { template in
            template.name.localizedCaseInsensitiveContains(query) ||
            template.category.localizedCaseInsensitiveContains(query)
        }
    }

    public func getTemplate(name: String) -> CodeTemplate? {
        templates.first { $0.name == name }
    }
}

/// 代码模板模型
public struct CodeTemplate: Identifiable {
    public let id = UUID()
    public let name: String
    public let icon: String
    public let category: String
    public let language: String
    public let code: String

    public init(name: String, icon: String, category: String, language: String, code: String) {
        self.name = name
        self.icon = icon
        self.category = category
        self.language = language
        self.code = code
    }
}

/// 代码片段管理器
public class SnippetManager {
    private let storage: SnippetStorage

    public init(storage: SnippetStorage) {
        self.storage = storage
    }

    public func saveSnippet(name: String, code: String, language: String, tags: [String] = []) throws {
        let snippet = CodeSnippet(
            name: name,
            code: code,
            language: language,
            tags: tags,
            createdAt: Date()
        )
        try storage.save(snippet)
    }

    public func getSnippet(id: UUID) throws -> CodeSnippet? {
        try storage.get(id: id)
    }

    public func searchSnippets(query: String) throws -> [CodeSnippet] {
        let all = try storage.getAll()
        if query.isEmpty {
            return all
        }

        return all.filter { snippet in
            snippet.name.localizedCaseInsensitiveContains(query) ||
            snippet.code.localizedCaseInsensitiveContains(query) ||
            snippet.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    public func deleteSnippet(id: UUID) throws {
        try storage.delete(id: id)
    }
}

public struct CodeSnippet: Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let code: String
    public let language: String
    public let tags: [String]
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, code: String, language: String, tags: [String], createdAt: Date) {
        self.id = id
        self.name = name
        self.code = code
        self.language = language
        self.tags = tags
        self.createdAt = createdAt
    }
}

public protocol SnippetStorage {
    func save(_ snippet: CodeSnippet) throws
    func get(id: UUID) throws -> CodeSnippet?
    func getAll() throws -> [CodeSnippet]
    func delete(id: UUID) throws
}

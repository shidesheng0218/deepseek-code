import Foundation

/// User-facing wording for durable tool activity. The raw tool identifier is
/// retained in the event log and Evidence inspector, but never needs to be
/// the primary label a developer reads during a conversation.
public struct ToolPresentation: Codable, Equatable, Sendable {
    public let title: String
    public let pendingDetail: String
    public let runningDetail: String
    public let completedDetail: String

    public init(title: String, pendingDetail: String, runningDetail: String, completedDetail: String) {
        self.title = title
        self.pendingDetail = pendingDetail
        self.runningDetail = runningDetail
        self.completedDetail = completedDetail
    }
}

public enum ToolPresentationResolver {
    public static func presentation(for tool: String) -> ToolPresentation {
        let name = tool.lowercased()
        switch name {
        case "web_search":
            return ToolPresentation(title: "联网搜索", pendingDetail: "准备搜索公开资料", runningDetail: "正在搜索公开资料", completedDetail: "已找到可引用来源")
        case "web_fetch":
            return ToolPresentation(title: "读取网页", pendingDetail: "准备读取公开网页", runningDetail: "正在提取网页内容", completedDetail: "网页证据已记录")
        case "run_command", "terminal.exec", "terminal.open":
            return ToolPresentation(title: "终端命令", pendingDetail: "等待命令执行", runningDetail: "正在执行命令", completedDetail: "命令已完成")
        case "apply_patch":
            return ToolPresentation(title: "代码修改", pendingDetail: "等待写入变更", runningDetail: "正在应用代码修改", completedDetail: "代码修改已应用")
        case "read_file", "list_directory", "search_workspace", "workspace_read_evidence", "lsp_query":
            return ToolPresentation(title: "读取项目", pendingDetail: "准备读取项目内容", runningDetail: "正在读取项目内容", completedDetail: "项目证据已记录")
        default:
            if name.hasPrefix("browser.") {
                return ToolPresentation(title: "浏览器验证", pendingDetail: "准备检查页面", runningDetail: "正在检查页面", completedDetail: "浏览器证据已记录")
            }
            if name.hasPrefix("github.") || name.hasPrefix("git") {
                return ToolPresentation(title: "Git 操作", pendingDetail: "等待 Git 操作", runningDetail: "正在处理 Git 操作", completedDetail: "Git 操作已完成")
            }
            return ToolPresentation(title: "工具操作", pendingDetail: "等待执行", runningDetail: "正在处理", completedDetail: "已完成")
        }
    }
}

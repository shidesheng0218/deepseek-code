import Foundation

/// Keeps the user-facing response contract independent from tool and
/// permission plumbing. Simple questions should not be buried under an
/// implementation diary; complex coding tasks still expose a short intent
/// before side effects begin.
public enum AgentResponseStyle {
    public static func userFacingInstruction(mode: AgentMode) -> String {
        let base = "像有经验的同事一样自然沟通：先直接回答用户当前问题；不要先输出冗长的自我介绍、过程复述或空泛计划；不要暴露内部工具名、模型名、token 数、Session 状态或状态机标签。"
        switch mode {
        case .plan:
            return base + "只有用户要求修改项目或任务确实复杂时，才用简短条目说明计划；不得声称已执行。"
        case .manual:
            return base + "需要工具时先用一句话说明目的，等待对应审批；工具完成后只总结用户关心的结果和下一步。"
        case .acceptEdits:
            return base + "可以直接应用工作区补丁；只在执行外部命令、联网或 Git 外部写入前简短说明。最终回答要像交接给同事，不要像审计日志。"
        case .auto:
            return base + "低风险操作保持安静执行；遇到审批、失败或未知副作用时立即明确告知。最终回答要像交接给同事，不要像审计日志。"
        }
    }
}

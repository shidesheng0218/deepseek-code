#!/bin/bash
# 查找最近的会话日志并检查事件
SESSION_DIR="$HOME/Library/Application Support/DeepSeek Code/sessions"
if [ -d "$SESSION_DIR" ]; then
    echo "=== 最近的会话 ==="
    ls -lt "$SESSION_DIR"/*.jsonl 2>/dev/null | head -3

    echo -e "\n=== 最新会话的最后50个事件 ==="
    LATEST=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -f "$LATEST" ]; then
        echo "文件: $LATEST"
        echo -e "\n事件类型统计:"
        jq -r '.type' "$LATEST" 2>/dev/null | sort | uniq -c

        echo -e "\n最后10个事件:"
        tail -10 "$LATEST" | jq -r '"\(.sequence) \(.type)"' 2>/dev/null

        echo -e "\nagent_completed 事件:"
        grep "agent_completed" "$LATEST" | tail -3 | jq . 2>/dev/null

        echo -e "\nassistant_text 事件数量:"
        grep "assistant_text" "$LATEST" | wc -l
    else
        echo "没有找到会话日志文件"
    fi
else
    echo "会话目录不存在: $SESSION_DIR"
fi

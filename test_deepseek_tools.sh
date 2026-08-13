#!/bin/bash

# 测试 DeepSeek API 的工具调用功能

API_KEY="${DEEPSEEK_API_KEY}"
if [ -z "$API_KEY" ]; then
    echo "错误：请设置 DEEPSEEK_API_KEY 环境变量"
    exit 1
fi

echo "测试 DeepSeek API 工具调用..."
echo ""

curl -X POST https://api.deepseek.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "model": "deepseek-chat",
    "messages": [
      {
        "role": "user",
        "content": "明天北京的天气如何？"
      }
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "web_search",
          "description": "Search the web for information",
          "parameters": {
            "type": "object",
            "properties": {
              "query": {
                "type": "string",
                "description": "The search query"
              }
            },
            "required": ["query"]
          }
        }
      }
    ],
    "stream": false
  }' | python3 -m json.tool

echo ""
echo "如果 API 返回了 tool_calls，说明工具调用正常工作"
echo "如果只返回文本，说明 DeepSeek 可能没有调用工具"

#!/usr/bin/env python3
import urllib.request
import json
import os

API_KEY = os.environ.get("DEEPSEEK_API_KEY")
if not API_KEY:
    raise SystemExit("请先设置 DEEPSEEK_API_KEY 环境变量")

payload = {
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
    "stream": False
}

print("测试 DeepSeek API 工具调用...")
print("")

try:
    req = urllib.request.Request(
        "https://api.deepseek.com/v1/chat/completions",
        data=json.dumps(payload).encode('utf-8'),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}"
        }
    )

    with urllib.request.urlopen(req, timeout=60) as response:
        result = json.loads(response.read().decode('utf-8'))

    print(json.dumps(result, indent=2, ensure_ascii=False))

    print("\n" + "="*60)

    if "choices" in result and len(result["choices"]) > 0:
        message = result["choices"][0]["message"]

        if "tool_calls" in message and message["tool_calls"]:
            print("✅ 成功！DeepSeek 返回了工具调用:")
            for tool_call in message["tool_calls"]:
                print(f"   - 工具: {tool_call['function']['name']}")
                print(f"   - 参数: {tool_call['function']['arguments']}")
        else:
            print("❌ DeepSeek 没有返回工具调用，只返回了文本:")
            print(f"   {message.get('content', '')}")

except Exception as e:
    print(f"错误: {e}")
    import traceback
    traceback.print_exc()

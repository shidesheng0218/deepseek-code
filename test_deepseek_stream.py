#!/usr/bin/env python3
import requests
import json
import os

API_KEY = os.environ.get("DEEPSEEK_API_KEY")
if not API_KEY:
    raise SystemExit("请先设置 DEEPSEEK_API_KEY 环境变量")
BASE_URL = "https://api.deepseek.com/v1"

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

data = {
    "model": "deepseek-chat",
    "messages": [
        {"role": "user", "content": "北京明天天气怎么样"}
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "web_search",
                "description": "搜索网页获取实时信息",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "搜索关键词"
                        }
                    },
                    "required": ["query"]
                }
            }
        }
    ],
    "stream": True
}

print("🔍 Testing DeepSeek streaming API with tools...\n")

response = requests.post(
    f"{BASE_URL}/chat/completions",
    headers=headers,
    json=data,
    stream=True
)

print(f"Status: {response.status_code}\n")

if response.status_code != 200:
    print("Error response:")
    print(response.text)
    exit(1)

for line in response.iter_lines():
    if line:
        line_str = line.decode('utf-8')
        if line_str.startswith('data: '):
            data_str = line_str[6:]
            if data_str != '[DONE]':
                try:
                    chunk = json.loads(data_str)
                    print(json.dumps(chunk, indent=2, ensure_ascii=False))
                    print("---")
                except:
                    print(f"Failed to parse: {data_str}")

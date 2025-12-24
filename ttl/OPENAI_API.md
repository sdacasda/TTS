# OpenAI 兼容 TTS API 文档

本服务提供了与 OpenAI TTS API 兼容的接口，可以直接替换 OpenAI 的语音合成服务。

## API 端点

```
POST http://your-server:8000/v1/audio/speech
```

## 请求格式

### Headers
```
Content-Type: application/json
```

### Body (JSON)
```json
{
  "model": "tts-1",
  "input": "你好，这是一个测试",
  "voice": "zh-CN-XiaoxiaoNeural",
  "response_format": "mp3",
  "speed": 1.0
}
```

### 参数说明

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model` | string | 是 | TTS 模型名称（任意字符串，内部映射到 Azure 语音） |
| `input` | string | 是 | 要合成的文本内容 |
| `voice` | string | 是 | Azure 语音名称（如 `zh-CN-XiaoxiaoNeural`） |
| `response_format` | string | 否 | 音频格式：`mp3`（默认）、`wav`、`opus`、`pcm` |
| `speed` | float | 否 | 语速（0.25-4.0），默认 1.0 |
| `gain` | float | 否 | 音量增益（dB），兼容参数，暂未使用 |
| `sample_rate` | int | 否 | 采样率（Hz），兼容参数，暂未使用 |

## 响应格式

成功时返回音频文件的二进制数据：

```
Content-Type: audio/mpeg (或 audio/wav 等)
Body: <binary audio data>
```

错误时返回 JSON：

```json
{
  "detail": "Error message"
}
```

## 支持的语音

### 中文语音
- `zh-CN-XiaoxiaoNeural` - 晓晓（女声）
- `zh-CN-YunxiNeural` - 云希（男声）
- `zh-CN-YunjianNeural` - 云健（男声）
- `zh-CN-XiaoyiNeural` - 晓伊（女声）
- 更多语音请访问：http://your-server:8000/api/tts/voices

### 英文语音
- `en-US-JennyNeural` - Jenny（女声）
- `en-US-GuyNeural` - Guy（男声）
- `en-US-AriaNeural` - Aria（女声）

## 语速映射

OpenAI 格式的 `speed` 参数（0.25-4.0）会自动转换为 Azure 的百分比格式：

- `speed: 0.5` → Azure rate: -50%
- `speed: 1.0` → Azure rate: 0% (正常)
- `speed: 1.5` → Azure rate: +50%
- `speed: 2.0` → Azure rate: +100%

## 使用示例

### cURL
```bash
curl -X POST http://your-server:8000/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tts-1",
    "input": "你好，这是一个测试",
    "voice": "zh-CN-XiaoxiaoNeural",
    "response_format": "mp3",
    "speed": 1.2
  }' \
  --output speech.mp3
```

### Python
```python
import requests

url = "http://your-server:8000/v1/audio/speech"
payload = {
    "model": "tts-1",
    "input": "你好，这是一个测试",
    "voice": "zh-CN-XiaoxiaoNeural",
    "response_format": "mp3",
    "speed": 1.0
}

response = requests.post(url, json=payload)

if response.status_code == 200:
    with open("output.mp3", "wb") as f:
        f.write(response.content)
    print("语音合成成功")
else:
    print(f"错误: {response.json()}")
```

### JavaScript/Node.js
```javascript
const fetch = require('node-fetch');
const fs = require('fs');

async function synthesizeSpeech() {
  const response = await fetch('http://your-server:8000/v1/audio/speech', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'tts-1',
      input: '你好，这是一个测试',
      voice: 'zh-CN-XiaoxiaoNeural',
      response_format: 'mp3',
      speed: 1.0
    })
  });

  if (response.ok) {
    const buffer = await response.buffer();
    fs.writeFileSync('output.mp3', buffer);
    console.log('语音合成成功');
  } else {
    console.error('错误:', await response.json());
  }
}

synthesizeSpeech();
```

## 配置 astrbot_plugin_tts_emotion_router

要在 AstrBot TTS 情绪路由插件中使用本服务，按以下方式配置：

### 插件配置文件
```yaml
# API 配置
api:
  url: "http://your-server:8000"  # 你的服务器地址
  key: "dummy-key"                 # 任意字符串即可（兼容性参数）
  model: "tts-1"                   # 模型名称（任意）
  format: "mp3"                    # 音频格式
  speed: 1.0                       # 默认语速
  gain: 5.0                        # 音量增益

# 音色映射（关键配置）
voice_map:
  neutral: "zh-CN-XiaoxiaoNeural"    # 中性音色
  happy: "zh-CN-XiaoyiNeural"        # 开心音色
  sad: "zh-CN-YunyangNeural"         # 难过音色
  angry: "zh-CN-YunjianNeural"       # 愤怒音色

# 语速映射
speed_map:
  neutral: 1.0
  happy: 1.2
  sad: 0.85
  angry: 1.1
```

## 获取可用语音列表

访问以下端点获取所有可用的 Azure 语音：

```bash
curl http://your-server:8000/api/tts/voices
```

筛选中文语音：

```bash
curl "http://your-server:8000/api/tts/voices?locale=zh-CN"
```

## 错误代码

| 状态码 | 说明 |
|--------|------|
| 200 | 成功 |
| 400 | 请求参数错误（如空文本） |
| 502 | Azure 语音服务错误 |
| 500 | 服务器内部错误 |

## 限制

- 支持的文本长度：取决于 Azure 限制
- 支持的语速范围：0.25-4.0（自动转换为 Azure 的 -50% 到 +200%）
- 音频格式：mp3, wav, opus, pcm
- 采样率：固定为 16kHz

## 更新服务

在服务器上执行：

```bash
docker compose restart
```

或使用在线更新按钮自动更新代码并重启服务。

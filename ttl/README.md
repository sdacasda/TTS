# Azure Speech Free(F0) Portal

面向 Azure Speech Free(F0) 套餐的语音门户，包含语音合成、语音识别与发音评测的简单 Web 界面和接口代理。

## 环境要求

- Docker 24+ 与 docker compose 插件。
- 必需：Azure 语音资源的 `SPEECH_KEY` 与 `SPEECH_REGION`。
- 可选：`OPENAI_TTS_API_KEY`，用于向兼容 OpenAI TTS 的后端发送 `api-key` 头。

## 快速开始：本地构建（Docker Compose）

1. 复制环境变量示例：

   ```bash
   cp .env.example .env
   ```

2. 编辑 `.env`，填写 `SPEECH_KEY`、`SPEECH_REGION`（可选：`OPENAI_TTS_API_KEY`）。
3. 启动服务：

   ```bash
   docker compose up -d --build
   ```

4. 访问应用：`http://<你的服务器>:8000`。

## 使用预构建镜像：docker 拉取安装

如果已将本仓库的 `backend/Dockerfile` 构建并推送到镜像仓库（如 GHCR 或 Docker Hub），可直接拉取运行：

```bash
cp .env.example .env
# 编辑 .env 填好 SPEECH_KEY / SPEECH_REGION（可选 OPENAI_TTS_API_KEY）
docker pull ghcr.io/your-namespace/speech-portal:latest
docker run -d --name speech-portal \
  --env-file .env \
  -p 8000:8000 \
  -v "$(pwd)/data:/app/data" \
  ghcr.io/your-namespace/speech-portal:latest
```

将 `ghcr.io/your-namespace/speech-portal:latest` 替换为你实际推送的镜像地址。

## 一键安装（克隆 + 运行）

```bash
git clone https://gist.github.com/<YOUR_GIST_ID>.git speech-portal \
  && cd speech-portal \
  && cp .env.example .env \
  && docker compose up -d --build
```

## 配额说明

Azure Speech Free(F0) 无法通过统一 API 查询「剩余额度」，本项目通过本地计量粗略展示：

- 语音识别（STT）：统计音频时长秒数。
- 语音合成（TTS）：统计输入文本字符数。
- 发音评测：统计音频时长秒数。

可在 `.env` 中调整月度限额。

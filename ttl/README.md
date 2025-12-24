# Azure Speech Free(F0) Portal

面向 Azure Speech Free(F0) 套餐的语音门户，包含语音合成、语音识别与发音评测的简单 Web 界面和接口代理。

## 环境要求

- Docker 24+ 与 docker compose 插件
- 必需：Azure 语音资源的 `SPEECH_KEY` 与 `SPEECH_REGION`
- 可选：`OPENAI_TTS_API_KEY`，用于向兼容 OpenAI TTS 的后端发送 `api-key` 头

## 🚀 一键安装（服务器部署推荐）

### 方式 A：快速安装（推荐，无交互）

**适用场景：** 服务器环境，不想手动输入配置

```bash
# 设置环境变量
export SPEECH_KEY='你的Azure密钥'
export SPEECH_REGION='你的区域'  # 如: eastasia, westus

# 执行安装
bash <(curl -fsSL https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/quick-install.sh)
```

一条命令示例（替换为你的实际密钥）：
```bash
export SPEECH_KEY='a1b2c3d4e5f6...' && export SPEECH_REGION='eastasia' && bash <(curl -fsSL https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/quick-install.sh)
```

### 方式 B：交互式安装

无需手动克隆仓库，脚本会引导你输入配置：

**Linux / macOS:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/install.sh)
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/install.ps1 | iex
```

交互式安装脚本会：
1. ✅ 检查系统依赖（Git, Docker, Docker Compose）
2. ✅ 自动从默认仓库克隆代码
3. ✅ 交互式输入 Azure Speech Service 配置
4. ✅ 验证密钥连接
5. ✅ 自动启动服务

---

## 📦 手动部署

### 方式一：使用交互式配置脚本（推荐）

**适用场景：** 已经克隆了代码，只需要配置环境变量

**Windows (PowerShell):**
```powershell
cd ttl
.\setup.ps1
docker compose up -d --build
```

**Linux / macOS:**
```bash
cd ttl
chmod +x setup.sh
./setup.sh
docker compose up -d --build
```

脚本会引导您：
- 输入 Azure Speech Service 密钥和区域
- 可选：配置使用配额限制
- 自动验证连接
- 生成 `.env` 配置文件

### 方式二：传统手动配置

1. 复制环境变量示例：

   ```bash
   cp .env.example .env
   ```

2. 编辑 `.env`，填写 `SPEECH_KEY`、`SPEECH_REGION`（可选：`OPENAI_TTS_API_KEY`）

3. 启动服务：

   ```bash
   docker compose up -d --build
   ```

### 方式三：使用预构建镜像

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

---

## 🌐 访问服务

启动后访问：`http://<你的服务器>:8000`

## 📊 配额说明

Azure Speech Free(F0) 无法通过统一 API 查询「剩余额度」，本项目通过本地计量粗略展示：

- **语音识别（STT）**：统计音频时长秒数
- **语音合成（TTS）**：统计输入文本字符数
- **发音评测**：统计音频时长秒数

可在 `.env` 中调整月度限额。

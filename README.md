# Azure Speech Free(F0) Portal

> 📖 **完整文档请查看：[根目录 README](../README.md)**

## 快速开始

本目录包含 Azure Speech 语音门户的完整实现。

### 🚀 一键安装

```bash
# Linux / macOS
bash <(curl -fsSL https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/install.sh)

# Windows PowerShell
irm https://raw.githubusercontent.com/sdacasda/TTS/main/ttl/install.ps1 | iex
```

### 📦 手动部署

如果已经克隆代码：

```bash
cd ttl
cp .env.example .env
# 编辑 .env 填写 SPEECH_KEY 和 SPEECH_REGION
docker compose up -d --build
```

### 📚 更多信息

- 详细安装指南：[../README.md](../README.md)
- 环境配置说明：[.env.example](.env.example)
- 交互式配置：`./setup.sh` 或 `.\setup.ps1`

---

**访问地址：** http://localhost:8000

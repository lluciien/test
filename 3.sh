#!/bin/bash

# ==============================================================================
# Script to set up keep-alive server and logger for Cloud Studio
# ==============================================================================

echo "🚀 正在创建所需文件和脚本..."
echo ""

# ------------------------------------------------------------------------------
# 1. 创建 Node.js Express 保活服务器 (keep-alive-server.js)
# ------------------------------------------------------------------------------
cat << 'EOF' > keep-alive-server.js
const express = require('express');
const app = express();
const port = 8080; // 你可以根据需要更改端口

app.get('/keep-alive', (req, res) => {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] Keep-alive endpoint hit from ${req.ip}`);
  res.status(200).send('OK');
});

app.listen(port, '0.0.0.0', () => { // 监听所有网络接口
  console.log(`✅ Keep-alive server listening on http://0.0.0.0:${port}/keep-alive`);
  console.log(`   请确保 Uptime Kuma 可以访问到此地址 (例如 http://localhost:${port}/keep-alive)`);
});

// 可选：添加一个根路径方便测试
app.get('/', (req, res) => {
  res.send('Keep-alive server is running. Visit /keep-alive');
});
EOF

echo "✅ 'keep-alive-server.js' 已创建。"
echo "   功能: 提供一个 HTTP 端点 (/keep-alive)，Uptime Kuma 将会访问此端点以保持 Cloud Studio 活跃。"
echo "   端口: 8080 (可在文件中修改)"
echo ""

# ------------------------------------------------------------------------------
# 2. 创建日志记录脚本 (logger.sh)
# ------------------------------------------------------------------------------
cat << 'EOF' > logger.sh
#!/bin/bash
LOG_FILE="cloud_studio_activity_log.txt" # 日志文件名
mkdir -p "$(dirname "${LOG_FILE}")" # 确保目录存在

echo "📝 Logger started. Logging to ${LOG_FILE}"
while true; do
  TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S %Z")
  echo "[${TIMESTAMP}] Cloud Studio is active." >> "${LOG_FILE}"
  # 可选：输出到控制台，如果不是通过 pm2 的 no-daemon 模式运行
  # echo "[${TIMESTAMP}] Cloud Studio is active. Logged to ${LOG_FILE}"
  sleep 30
done
EOF

chmod +x logger.sh

echo "✅ 'logger.sh' 已创建并设为可执行。"
echo "   功能: 每30秒向 'cloud_studio_activity_log.txt' 文件写入一条日志，用于验证 Cloud Studio 是否持续运行。"
echo ""

# ==============================================================================
# 完成文件创建！下一步是手动执行以下操作：
# ==============================================================================
echo "------------------------------------------------------------------------------"
echo "📌 请按顺序执行以下步骤来完成配置："
echo "------------------------------------------------------------------------------"
echo ""
echo "📦 步骤 1: 安装依赖 (如果尚未安装)"
echo "   确保你的 Cloud Studio 环境中已安装 Node.js, npm, 和 pm2。"
echo "   - 安装 Node.js 和 npm: (Cloud Studio 通常自带，若无请自行安装)"
echo "   - 安装 pm2 (全局):"
echo "     npm install -g pm2"
echo "   - 安装 express (在 'keep-alive-server.js' 所在目录):"
echo "     npm install express"
echo ""

echo "⚙️ 步骤 2: 启动保活服务器 (使用 pm2)"
echo "   cd 到 'keep-alive-server.js' 文件所在的目录，然后运行:"
echo "     pm2 start keep-alive-server.js --name cloud-keep-alive"
echo "   检查状态:"
echo "     pm2 list"
echo "     pm2 logs cloud-keep-alive"
echo ""

echo "📝 步骤 3: 启动日志记录脚本 (使用 pm2 或 nohup)"
echo "   cd 到 'logger.sh' 文件所在的目录，然后运行 (推荐 pm2):"
echo "     pm2 start ./logger.sh --name cloud-logger"
echo "   或者使用 nohup (如果不想用pm2):"
echo "     nohup ./logger.sh &"
echo "   检查日志文件:"
echo "     tail -f cloud_studio_activity_log.txt"
echo ""

echo "🔗 步骤 4: 确保 Uptime Kuma 正在运行并通过 ngrok 暴露 (如果需要从公网访问其UI)"
echo "   - Uptime Kuma 安装与运行 (参考你之前的设置，如 Docker 或 Node.js + pm2):"
echo "     例如 (Docker): docker run -d --restart=always -p 3001:3001 -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1"
echo "     例如 (Node.js with pm2, 假设已在 uptime-kuma 目录下): pm2 start server/server.js --name uptime-kuma"
echo ""
echo "   - 启动 ngrok 为 Uptime Kuma 的 UI (默认端口 3001):"
echo "     ./ngrok http 3001  (假设 ngrok 在当前目录或 PATH 中)"
echo "     ngrok 会提供一个公网 URL，例如 https://xxxxxx.ngrok-free.app"
echo ""

echo "📊 步骤 5: 配置 Uptime Kuma 监控项 (手动)"
echo "   1. 通过 ngrok 提供的公网地址 (或 http://localhost:3001 如果直接在 Cloud Studio 图形界面操作) 访问 Uptime Kuma。"
echo "   2. 如果是首次访问，创建管理员账户。"
echo "   3. 登录 Uptime Kuma。"
echo "   4. 点击仪表盘上的 “+ 添加监控” 或侧边栏的 “添加监控”。"
echo "   5. 配置监控项："
echo "      - **监控类型**: 选择 HTTP(s)"
echo "      - **友好名称**: 例如 'Cloud Studio Keep-Alive'"
echo "      - **URL**: 填写内部保活服务器的地址。由于 Uptime Kuma 和保活服务器都在 Cloud Studio 内部，通常是:"
echo "                 http://localhost:8080/keep-alive"
echo "                 (请确保这里的端口 '8080' 与 'keep-alive-server.js' 中配置的端口一致)"
echo "      - **心跳间隔**: 60 (秒)  (或你期望的保活频率)"
echo "      - **重试间隔**: 60 (秒)"
echo "      - **最大重试次数**: 3"
echo "      - 根据需要调整其他设置 (例如通知、超时等)。"
echo "   6. 点击页面底部的 “保存”。"
echo ""

echo "🛡️ 步骤 6: （可选）为 SSH 设置 ngrok 隧道 (如果需要)"
echo "   如果你之前用 `ngrok tcp 22` 来访问 SSH，确保这个隧道也在运行。"
echo "     ./ngrok tcp 22"
echo ""

echo "🔎 步骤 7: 验证"
echo "   - **Uptime Kuma**: 检查 Uptime Kuma 中的监控项是否显示 “UP” 状态，并且有规律的检测记录。"
echo "   - **ngrok 稳定性**: 观察 ngrok 客户端的输出，确保隧道连接稳定，地址没有频繁改变。"
echo "   - **Cloud Studio 持续运行**: 定期检查 'cloud_studio_activity_log.txt' 文件，确认时间戳持续更新，表明 'logger.sh' 脚本一直在运行。"
echo "     例如: tail -f cloud_studio_activity_log.txt"
echo ""
echo "🎉 全部指令已显示完毕。请按照上述步骤操作。"
echo "   祝你配置成功！"
echo "------------------------------------------------------------------------------"

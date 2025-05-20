#!/bin/bash
set -e # 如果任何命令失败，立即退出脚本

# --- 配置 ---
WORKSPACE_DIR="${HOME}/cloud_keepalive_setup" # 工作目录
KEEP_ALIVE_PORT="8080"                       # 保活服务器端口
UPTIME_KUMA_PORT="3001"                      # Uptime Kuma 默认端口
UPTIME_KUMA_CONTAINER_NAME="uptime-kuma"     # Uptime Kuma Docker 容器名
UPTIME_KUMA_VOLUME_NAME="uptime-kuma-data"   # Uptime Kuma Docker 数据卷名
NGROK_LOG_LEVEL="info"                       # ngrok 日志级别 (可改为 "debug")

# --- 辅助函数 ---
echo_step() { echo -e "\n\n✅ STEP: $1"; }
echo_info() { echo -e "INFO: $1"; }
echo_warn() { echo -e "WARN: $1"; }
echo_error() { echo -e "ERROR: $1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# --- Sudo 检测 ---
SUDO=""
if [ "$(id -u)" != "0" ]; then
  if command_exists sudo; then
    SUDO="sudo"
    echo_info "Sudo 将用于需要 root 权限的命令。"
  else
    echo_warn "未找到 sudo 命令。某些安装可能会失败。请以 root 用户身份运行脚本或安装 sudo。"
  fi
fi

# --- 主脚本 ---
echo_step "在 ${WORKSPACE_DIR} 初始化设置"
mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}" || echo_error "无法切换目录到 ${WORKSPACE_DIR}"
echo_info "当前工作目录: $(pwd)"

# 1. 依赖检查和安装
echo_step "检查并安装依赖项"

# Node.js 和 npm (尝试通过 NVM 安装，如果未找到)
if ! command_exists node || ! command_exists npm; then
  echo_warn "未找到 Node.js 或 npm。"
  echo_info "尝试使用 NVM 安装 Node.js (LTS) 和 npm..."
  if ! command_exists nvm; then
      echo_info "未找到 NVM。正在安装 NVM..."
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
      if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh" # 加载 nvm
        echo_info "NVM 已加载。请重新运行脚本，或在新终端中继续。"
        echo_info "或者，尝试手动运行: source ~/.bashrc (或 ~/.zshrc 等) 然后再试。"
        # NVM 安装后通常需要新的 shell 会话或 source .bashrc
        # 为了在此脚本中继续，我们尝试直接使用 nvm
         if command_exists nvm; then
            nvm install --lts
            nvm use --lts # 确保在当前会话中使用
            nvm alias default 'lts/*' # 设置默认版本
         else
            echo_error "NVM 安装后似乎仍不可用。请打开新终端并重试，或手动安装 Node.js 和 npm。"
         fi
      else
        echo_error "NVM 安装脚本执行了，但 nvm.sh 未找到。请检查 NVM 安装。"
      fi
  else # NVM 存在
    echo_info "NVM 已安装。使用 NVM 安装/切换到 LTS Node.js..."
    nvm install --lts
    nvm use --lts
    nvm alias default 'lts/*'
  fi

  # 再次检查 Node 和 npm
  if ! command_exists node || ! command_exists npm; then
    echo_error "尝试通过 NVM 安装后，Node.js 或 npm 仍未找到。请手动安装它们。"
  fi
fi
echo_info "Node 版本: $(node -v), npm 版本: $(npm -v)"

# pm2
if ! command_exists pm2; then
  echo_info "未找到 pm2。正在全局安装 pm2..."
  npm install -g pm2 || echo_error "安装 pm2 失败。"
fi
echo_info "pm2 版本: $(pm2 --version)"

# Docker
DOCKER_OK=false
DOCKER_CMD=""
if command_exists docker; then
  # 尝试在没有 sudo 的情况下运行 docker ps
  if docker ps > /dev/null 2>&1; then
    echo_info "Docker 已安装且当前用户可访问。"
    DOCKER_CMD="docker"
    DOCKER_OK=true
  elif ${SUDO} docker ps > /dev/null 2>&1; then
    echo_warn "Docker 已安装，但当前用户无法直接访问。将尝试使用 '${SUDO} docker'。"
    echo_info "你可能需要运行 '${SUDO} usermod -aG docker \$USER' 然后重新登录，以避免每次都使用 sudo。"
    DOCKER_CMD="${SUDO} docker"
    DOCKER_OK=true
  else
    echo_warn "Docker 已安装，但即使使用 sudo 也无法访问。请检查 Docker 安装和权限。"
  fi
else
  echo_warn "未找到 Docker。"
  echo_info "如果你的环境是 Debian/Ubuntu，可以尝试手动安装: ${SUDO} apt update && ${SUDO} apt install -y docker.io"
  echo_info "然后将用户添加到 docker 组: '${SUDO} usermod -aG docker \$USER' 并重新登录。"
fi

# ngrok
if ! command_exists ngrok; then
  echo_warn "未找到 ngrok 命令。请从 https://ngrok.com/download 下载并安装 ngrok，并确保它在你的 PATH 中。"
  echo_warn "安装后，不要忘记配置你的 Authtoken: ngrok config add-authtoken YOUR_AUTHTOKEN"
else
  echo_info "ngrok 已找到: $(ngrok version || echo '无法获取版本')"
  echo_info "请确保你的 ngrok Authtoken 已配置，以便获得稳定的隧道地址和更长的会话时间。"
fi


# 2. 创建保活服务器
echo_step "创建 Node.js 保活服务器 (keep-alive-server.js)"
cat << EOF > keep-alive-server.js
const express = require('express');
const app = express();
const port = ${KEEP_ALIVE_PORT};

app.get('/keep-alive', (req, res) => {
  const timestamp = new Date().toISOString();
  console.log(\`[\${timestamp}] Keep-alive endpoint hit from \${req.ip}\`);
  res.status(200).send('OK');
});

app.listen(port, '0.0.0.0', () => {
  console.log(\`保活服务器正在监听 http://0.0.0.0:\${port}/keep-alive\`);
});

app.get('/', (req, res) => {
  res.send('保活服务器正在运行。请访问 /keep-alive 端点。');
});
EOF
echo_info "'keep-alive-server.js' 已创建。"
echo_info "安装 express 依赖..."
npm install express --save --no-audit --no-fund --loglevel=error || echo_error "安装 express 失败。"


# 3. 创建日志记录脚本
echo_step "创建日志记录脚本 (logger.sh)"
cat << EOF > logger.sh
#!/bin/bash
LOG_FILE="${WORKSPACE_DIR}/cloud_studio_activity_log.txt"
mkdir -p "\$(dirname "\${LOG_FILE}")"

echo "日志记录器已启动。正在记录到 \${LOG_FILE}"
while true; do
  TIMESTAMP=\$(date +"%Y-%m-%d %H:%M:%S %Z")
  echo "[\${TIMESTAMP}] Cloud Studio is active." >> "\${LOG_FILE}"
  sleep 30
done
EOF
chmod +x logger.sh
echo_info "'logger.sh' 已创建并设为可执行。"


# 4. 使用 pm2 启动服务
echo_step "使用 pm2 启动服务"

SERVICE_NAMES=("cloud-keep-alive" "cloud-logger")
for service_name in "${SERVICE_NAMES[@]}"; do
  if pm2 describe "$service_name" &>/dev/null; then
    echo_info "正在停止并删除已存在的 pm2 进程: $service_name"
    pm2 delete "$service_name" || echo_warn "删除 $service_name 失败，它可能已被部分注册或已移除。"
  fi
done

echo_info "使用 pm2 启动保活服务器..."
pm2 start keep-alive-server.js --name cloud-keep-alive || echo_error "使用 pm2 启动 keep-alive-server.js 失败。"

echo_info "使用 pm2 启动日志记录脚本..."
pm2 start ./logger.sh --name cloud-logger || echo_error "使用 pm2 启动 logger.sh 失败。"

pm2 save || echo_warn "pm2 save 命令失败。进程列表可能不会在重启后保留。" # 保存 pm2 进程列表

# 5. 使用 Docker 设置 Uptime Kuma
echo_step "使用 Docker 设置 Uptime Kuma"
if [ "$DOCKER_OK" = true ] && [ -n "$DOCKER_CMD" ]; then
  # 检查容器是否正在运行
  if ! $DOCKER_CMD ps -q -f name="^/${UPTIME_KUMA_CONTAINER_NAME}$" | grep -q .; then
    # 检查容器是否存在但已停止
    if $DOCKER_CMD ps -aq -f status=exited -f name="^/${UPTIME_KUMA_CONTAINER_NAME}$" | grep -q .; then
        echo_info "Uptime Kuma 容器 '${UPTIME_KUMA_CONTAINER_NAME}' 已存在但已停止。尝试移除并重启..."
        $DOCKER_CMD rm "${UPTIME_KUMA_CONTAINER_NAME}" || echo_warn "移除已停止的 Uptime Kuma 容器失败。"
    # 检查容器是否以任何状态存在（除了上面指定的正在运行或已停止）
    elif $DOCKER_CMD ps -aq -f name="^/${UPTIME_KUMA_CONTAINER_NAME}$" | grep -q .; then
        echo_info "Uptime Kuma 容器 '${UPTIME_KUMA_CONTAINER_NAME}' 已存在。尝试强制移除并重新创建以确保配置正确。"
        $DOCKER_CMD rm -f "${UPTIME_KUMA_CONTAINER_NAME}" || echo_warn "强制移除已存在的 Uptime Kuma 容器失败。"
    fi
    echo_info "正在启动 Uptime Kuma Docker 容器 (后台运行)..."
    $DOCKER_CMD run -d --restart=always \
      -p "${UPTIME_KUMA_PORT}:${UPTIME_KUMA_PORT}" \
      -v "${UPTIME_KUMA_VOLUME_NAME}:/app/data" \
      --name "${UPTIME_KUMA_CONTAINER_NAME}" \
      louislam/uptime-kuma:1 || echo_error "启动 Uptime Kuma 容器失败。"
    echo_info "Uptime Kuma 容器已启动。它可能需要一分钟左右才能完全准备就绪。"
  else
    echo_info "Uptime Kuma 容器 '${UPTIME_KUMA_CONTAINER_NAME}' 已在运行。"
  fi
else
  echo_warn "Docker 不可用或未正确配置。跳过 Uptime Kuma Docker 设置。"
  echo_info "请手动安装并运行 Uptime Kuma。"
fi

# 6. 使用 pm2 启动 ngrok 隧道
echo_step "使用 pm2 启动 ngrok 隧道"
if command_exists ngrok; then
  NGROK_PM2_UPTIME_KUMA="ngrok-uptime-kuma"
  NGROK_PM2_SSH="ngrok-ssh"

  # Uptime Kuma ngrok 隧道
  if pm2 describe "$NGROK_PM2_UPTIME_KUMA" &>/dev/null; then
    echo_info "正在停止并删除已存在的 pm2 ngrok 进程: $NGROK_PM2_UPTIME_KUMA"
    pm2 delete "$NGROK_PM2_UPTIME_KUMA" || echo_warn "删除 $NGROK_PM2_UPTIME_KUMA 失败。"
  fi
  echo_info "正在为 Uptime Kuma UI (端口 ${UPTIME_KUMA_PORT}) 启动 ngrok 隧道..."
  pm2 start ngrok --name "$NGROK_PM2_UPTIME_KUMA" -- \
    http "${UPTIME_KUMA_PORT}" --log stdout --log-level "${NGROK_LOG_LEVEL}" || echo_warn "为 Uptime Kuma 启动 ngrok 失败。"

  # SSH ngrok 隧道
  if pm2 describe "$NGROK_PM2_SSH" &>/dev/null; then
    echo_info "正在停止并删除已存在的 pm2 ngrok 进程: $NGROK_PM2_SSH"
    pm2 delete "$NGROK_PM2_SSH" || echo_warn "删除 $NGROK_PM2_SSH 失败。"
  fi
  echo_info "正在为 SSH (端口 22) 启动 ngrok 隧道..."
  pm2 start ngrok --name "$NGROK_PM2_SSH" -- \
    tcp 22 --log stdout --log-level "${NGROK_LOG_LEVEL}" || echo_warn "为 SSH 启动 ngrok 失败。"

  pm2 save || echo_warn "pm2 save 命令失败。"
  echo_info "ngrok 隧道已通过 pm2 启动。它们可能需要一些时间来建立连接。"
  echo_info "你需要通过 'pm2 logs $NGROK_PM2_UPTIME_KUMA' 和 'pm2 logs $NGROK_PM2_SSH' 来检查它们的公网 URL。"
else
  echo_warn "未找到 ngrok。跳过 ngrok 隧道设置。"
fi

# 7. 最终说明
echo_step "设置基本完成！仍需手动完成以下最终步骤："
echo_info "------------------------------------------------------------------------------"
pm2 list
echo ""
echo_info "1. 获取 Uptime Kuma 的 ngrok URL:"
echo_info "   运行: pm2 logs ${NGROK_PM2_UPTIME_KUMA:-ngrok-uptime-kuma}"
echo_info "   查找类似 'url=https://xxxxxx.ngrok-free.app' 或 'msg=\"started tunnel\" proto=http addr=http://localhost:${UPTIME_KUMA_PORT} url=https://YOUR_URL.ngrok-free.app' 的行。"
echo_info "   URL 可能在启动后 10-30 秒才会出现在日志中。"
echo ""
echo_info "2. 访问并配置 Uptime Kuma:"
echo_info "   - 在浏览器中打开上面获取到的 Uptime Kuma 的 ngrok URL。"
echo_info "   - 如果是首次访问，请在 Uptime Kuma 中创建管理员账户。"
echo_info "   - 登录后，添加一个新的监控项："
echo_info "     - 监控类型: HTTP(s)"
echo_info "     - 友好名称: 例如 'Cloud Studio Keep-Alive'"
echo_info "     - URL: http://localhost:${KEEP_ALIVE_PORT}/keep-alive  (这是 Cloud Studio 内部地址)"
echo_info "     - 心跳间隔: 60 (秒)"
echo_info "     - 点击 “保存”。"
echo ""
echo_info "3. 获取 SSH 的 ngrok URL (如果需要):"
echo_info "   运行: pm2 logs ${NGROK_PM2_SSH:-ngrok-ssh}"
echo_info "   查找类似 'url=tcp://0.tcp.jp.ngrok.io:XXXXX' 的行。"
echo ""
echo_info "4. 验证保活日志记录器:"
echo_info "   检查日志文件: tail -f \"${WORKSPACE_DIR}/cloud_studio_activity_log.txt\""
echo ""
echo_info "5. 后续管理服务:"
echo_info "   pm2 list                       # 列出所有 pm2 进程"
echo_info "   pm2 logs <进程名>             # 查看指定进程的日志"
echo_info "   pm2 stop/restart/delete <进程名> # 管理进程"
echo_info "   pm2 save                       # 保存当前 pm2 进程列表以便重启后恢复"
echo_info "   ${SUDO}pm2 startup             # (可选) 生成在系统启动时运行 pm2 的命令"
echo ""
echo_info "🎉 脚本执行完毕。"
echo_info "------------------------------------------------------------------------------"

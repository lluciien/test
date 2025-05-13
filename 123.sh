#!/bin/bash

# --- 用户配置 ---
# 请将以下替换为您的 frps 服务器信息
FRPS_ADDR="117.72.80.188"
FRPS_PORT="7777"

# frpc 代理配置内容 (TOML 格式)
# 您可以根据需求修改或添加更多代理
# 注意：下面的 FRPC_CONFIG_CONTENT 中的变量 $FRPS_ADDR 和 $FRPS_PORT 不会被 bash 展开，它们是给 frpc.toml 文件的字面量
# TOML 文件中的 serverAddr 和 serverPort 值将在下面通过 echo 命令动态写入
FRPC_BASE_CONFIG_PART='
[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000

# 示例: 代理本地的 Web 服务 (HTTP)
# [[proxies]]
# name = "web_example"
# type = "http"
# localPort = 8080
# customDomains = ["your.example.com"] # 如果您的 frps 服务端配置了域名

# 示例: 代理另一个 TCP 服务
# [[proxies]]
# name = "another_tcp_service"
# type = "tcp"
# localIP = "127.0.0.1"
# localPort = 3000
# remotePort = 6001
'
# --- 脚本常量 ---
FRPC_EXECUTABLE_NAME="frpc"
FRPC_CONFIG_FILE="frpc.toml"
GITHUB_REPO="fatedier/frp"

# --- 依赖检查 ---
echo "正在检查依赖工具..."
MISSING_TOOLS=()
command -v curl >/dev/null 2>&1 || MISSING_TOOLS+=("curl")
command -v jq >/dev/null 2>&1 || MISSING_TOOLS+=("jq")
command -v tar >/dev/null 2>&1 || MISSING_TOOLS+=("tar")

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "错误: 缺少以下依赖工具: ${MISSING_TOOLS[*]
    echo "请先安装它们后再运行此脚本。"
    echo "例如，在 Debian/Ubuntu 上: sudo apt update && sudo apt install curl jq tar"
    echo "在 macOS 上 (使用 Homebrew): brew install curl jq"
    exit 1
fi
echo "依赖工具检查完毕。"

# --- 操作系统和架构检测 ---
OS_KERNEL=$(uname -s)
OS_ARCH=$(uname -m)

case "$OS_KERNEL" in
    Linux)
        TARGET_OS="linux"
        ;;
    Darwin) # macOS
        TARGET_OS="darwin"
        ;;
    *)
        echo "错误: 不支持的操作系统: $OS_KERNEL. 此脚本仅支持 Linux 和 macOS。"
        exit 1
        ;;
esac

case "$OS_ARCH" in
    x86_64 | amd64)
        TARGET_ARCH="amd64"
        ;;
    aarch64 | arm64)
        TARGET_ARCH="arm64"
        ;;
    armv7l | arm)
        TARGET_ARCH="arm" # frp 可能对 32-bit ARM 有特定命名，如 "arm"
        ;;
    i386 | i686)
        TARGET_ARCH="386"
        ;;
    *)
        echo "错误: 不支持的处理器架构: $OS_ARCH"
        exit 1
        ;;
esac
ARCHIVE_SUFFIX=".tar.gz" # Linux 和 macOS 通常使用 .tar.gz

echo "检测到系统: $TARGET_OS, 架构: $TARGET_ARCH"

# --- 下载并提取 frpc ---
echo "正在从 GitHub API 获取最新的 frp 版本信息..."
LATEST_RELEASE_INFO_JSON=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")

if [ -z "$LATEST_RELEASE_INFO_JSON" ] || ! echo "$LATEST_RELEASE_INFO_JSON" | jq -e . >/dev/null 2>&1; then
    echo "错误：无法从 GitHub API 获取或解析最新版本信息。"
    exit 1
fi

TAG_NAME=$(echo "$LATEST_RELEASE_INFO_JSON" | jq -r '.tag_name')
VERSION=${TAG_NAME#v} # 移除版本号前的 'v' (例如 v0.58.1 -> 0.58.1)

if [ "$TAG_NAME" == "null" ] || [ -z "$TAG_NAME" ]; then
    echo "错误：无法从 API 响应中解析最新版本号。"
    exit 1
fi
echo "最新的 frp 版本: $TAG_NAME"

# 构建期望的文件名格式，例如 frp_0.58.1_linux_amd64.tar.gz
EXPECTED_ASSET_NAME_PATTERN="frp_${VERSION}_${TARGET_OS}_${TARGET_ARCH}${ARCHIVE_SUFFIX}"

DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO_JSON" | jq -r --arg name_pattern "$EXPECTED_ASSET_NAME_PATTERN" \
    '.assets[] | select(.name == $name_pattern) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo "错误: 未能找到适用于 $TARGET_OS $TARGET_ARCH 的 frp $TAG_NAME 下载链接 (期望文件名: $EXPECTED_ASSET_NAME_PATTERN)。"
    echo "您可以访问 https://github.com/${GITHUB_REPO}/releases 查看可用的发行包。"
    exit 1
fi

DOWNLOADED_ARCHIVE_FILENAME=$(basename "$DOWNLOAD_URL")
echo "准备下载: $DOWNLOADED_ARCHIVE_FILENAME 从 $DOWNLOAD_URL"

if [ -f "$DOWNLOADED_ARCHIVE_FILENAME" ]; then
    echo "文件 '$DOWNLOADED_ARCHIVE_FILENAME' 已存在，跳过下载。"
else
    curl -L -o "$DOWNLOADED_ARCHIVE_FILENAME" "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        echo "错误: 下载 '$DOWNLOADED_ARCHIVE_FILENAME' 失败。"
        exit 1
    fi
    echo "下载完成: $DOWNLOADED_ARCHIVE_FILENAME"
fi

echo "正在解压 $DOWNLOADED_ARCHIVE_FILENAME ..."
# frp 压缩包通常包含一个与版本相关的目录，如 frp_0.58.1_linux_amd64/
# 我们需要从这个目录中提取 frpc
# 创建一个临时目录来解压，避免污染当前目录
TEMP_EXTRACT_DIR="frp_temp_extract_$$" # 使用$$确保临时目录名唯一
mkdir -p "$TEMP_EXTRACT_DIR"

# 解压到临时目录
tar -xzf "$DOWNLOADED_ARCHIVE_FILENAME" -C "$TEMP_EXTRACT_DIR"
if [ $? -ne 0 ]; then
    echo "错误: 解压 '$DOWNLOADED_ARCHIVE_FILENAME' 失败。"
    rm -rf "$TEMP_EXTRACT_DIR" # 清理临时目录
    exit 1
fi

# 查找 frpc 可执行文件路径
# 通常在解压后的 frp_VERSION_OS_ARCH/frpc
EXTRACTED_CONTENT_DIR_NAME="frp_${VERSION}_${TARGET_OS}_${TARGET_ARCH}"
FRPC_PATH_IN_ARCHIVE="${TEMP_EXTRACT_DIR}/${EXTRACTED_CONTENT_DIR_NAME}/${FRPC_EXECUTABLE_NAME}"

if [ -f "$FRPC_PATH_IN_ARCHIVE" ]; then
    echo "已找到 frpc: $FRPC_PATH_IN_ARCHIVE"
    mv "$FRPC_PATH_IN_ARCHIVE" "./${FRPC_EXECUTABLE_NAME}"
    if [ $? -ne 0 ]; then
        echo "错误: 移动 '$FRPC_EXECUTABLE_NAME' 到当前目录失败。"
        rm -rf "$TEMP_EXTRACT_DIR"
        rm -f "$DOWNLOADED_ARCHIVE_FILENAME" # 清理下载的压缩包
        exit 1
    fi
    echo "'$FRPC_EXECUTABLE_NAME' 已移动到当前目录。"
else
    echo "错误: 未在解压后的目录 '${TEMP_EXTRACT_DIR}/${EXTRACTED_CONTENT_DIR_NAME}' 中找到 '${FRPC_EXECUTABLE_NAME}'。"
    echo "请检查压缩包结构或手动提取。"
    rm -rf "$TEMP_EXTRACT_DIR"
    rm -f "$DOWNLOADED_ARCHIVE_FILENAME"
    exit 1
fi

# 清理下载的压缩包和临时解压目录
echo "正在清理临时文件..."
rm -f "$DOWNLOADED_ARCHIVE_FILENAME"
rm -rf "$TEMP_EXTRACT_DIR"
echo "清理完毕。"

# --- 创建 frpc.toml 配置文件 ---
echo "正在创建配置文件: $FRPC_CONFIG_FILE"
cat << EOF > "$FRPC_CONFIG_FILE"
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}
${FRPC_BASE_CONFIG_PART}
EOF
echo "配置文件 '$FRPC_CONFIG_FILE' 创建成功。"

# --- 设置执行权限并运行 frpc ---
echo "正在为 '$FRPC_EXECUTABLE_NAME' 设置执行权限..."
chmod +x "./${FRPC_EXECUTABLE_NAME}"
if [ $? -ne 0 ]; then
    echo "错误: 设置执行权限失败 for './${FRPC_EXECUTABLE_NAME}'."
    exit 1
fi

echo "准备就绪，正在启动 frpc..."
echo "您可以使用 Ctrl+C 来停止 frpc。"
echo "-----------------------------------------------------"
"./${FRPC_EXECUTABLE_NAME}" -c "./${FRPC_CONFIG_FILE}"

# 脚本执行到这里时，frpc 会在前台运行。
# 如果 frpc 启动失败或退出，下面的语句可能不会执行。
echo "-----------------------------------------------------"
echo "frpc 已尝试启动。如果它没有持续运行，请检查上面的日志输出。"

exit 0

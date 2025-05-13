#!/bin/bash

# 天翼云电脑 Docker 保活一键部署脚本
# 请在您希望部署项目的目录下运行此脚本

echo "🚀 开始部署天翼云电脑 Docker 保活项目..."
echo "--------------------------------------------------"

# --- 配置 ---
CTYUN_DATA_DIR="ctyun" # 数据目录名称
DOCKER_COMPOSE_FILE="docker-compose.yml"
IMAGE_NAME="ghcr.nju.edu.cn/eleba88/keepctyun:latest"
CONTAINER_NAME="ctyun"
NETWORK_NAME="nasnet"
NETWORK_SUBNET="10.0.0.0/24"
NETWORK_MTU="1450"
PUID="10042" # puppeteer 镜像的用户ID
PGID="999"   # puppeteer 镜像的组ID

# --- 函数定义 ---

# 函数：检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 函数：检查或安装依赖
check_dependencies() {
    echo " STEP 1: 检查依赖 (Docker 和 Docker Compose)..."

    # 检查 Docker
    if ! command_exists docker; then
        echo "❌ 错误：未检测到 Docker。"
        echo "请先安装 Docker。您可以参考官方文档：https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker info > /dev/null 2>&1; then
        echo "❌ 错误：Docker 服务未运行或当前用户无权限访问 Docker socket。"
        echo "   请确保 Docker 服务已启动，并将当前用户添加到 'docker' 组（可能需要重新登录）："
        echo "     sudo groupadd docker  # 如果 'docker' 组不存在"
        echo "     sudo usermod -aG docker \$USER"
        echo "     newgrp docker  # 或者重新登录以使组更改生效"
        exit 1
    fi
    echo "✅ Docker 已安装并正在运行。"

    # 检查 Docker Compose (V1 或 V2)
    if command_exists docker-compose; then
        COMPOSE_CMD="docker-compose"
        echo "✅ Docker Compose (docker-compose) 已找到。"
    elif docker compose version > /dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        echo "✅ Docker Compose (docker compose V2) 已找到。"
    else
        echo "❌ 错误：未检测到 Docker Compose。"
        echo "请先安装 Docker Compose。您可以参考官方文档：https://docs.docker.com/compose/install/"
        echo "   对于 Docker Compose V1 (docker-compose)，常见安装方法是:"
        echo "     sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose"
        echo "     sudo chmod +x /usr/local/bin/docker-compose"
        echo "   对于 Docker Compose V2 (集成在 Docker CLI 中)，它通常随较新版本的 Docker Engine 一起安装。"
        exit 1
    fi
}

# 函数：创建 docker-compose.yml 文件
create_docker_compose_file() {
    echo " STEP 2: 创建 ${DOCKER_COMPOSE_FILE} 文件..."
    cat <<EOF > ${DOCKER_COMPOSE_FILE}
version: "3.8"
networks:
  ${NETWORK_NAME}:
    driver: bridge
    driver_opts:
      com.docker.network.driver.mtu: "${NETWORK_MTU}"
    ipam:
      config:
        - subnet: "${NETWORK_SUBNET}"
services:
  ${CONTAINER_NAME}:
    image: "${IMAGE_NAME}"
    container_name: "${CONTAINER_NAME}"
    networks:
      - "${NETWORK_NAME}"
    restart: always
    volumes:
      - "./${CTYUN_DATA_DIR}:/usr/src/server/data"
EOF
    if [ $? -ne 0 ]; then
        echo "❌ 错误：创建 ${DOCKER_COMPOSE_FILE} 文件失败。"
        exit 1
    fi
    echo "✅ ${DOCKER_COMPOSE_FILE} 文件创建成功于 $(pwd)/${DOCKER_COMPOSE_FILE}"
}

# 函数：创建数据目录并设置权限
create_data_directory() {
    echo " STEP 3: 创建数据目录 ./${CTYUN_DATA_DIR} 并设置权限..."
    if [ -d "${CTYUN_DATA_DIR}" ]; then
        echo "   ℹ️  目录 ./${CTYUN_DATA_DIR} 已存在，跳过创建。"
    else
        mkdir "${CTYUN_DATA_DIR}"
        if [ $? -ne 0 ]; then
            echo "❌ 错误：创建目录 ./${CTYUN_DATA_DIR} 失败。"
            exit 1
        fi
        echo "   ✅ 目录 ./${CTYUN_DATA_DIR} 创建成功。"
    fi

    echo "   ℹ️  正在设置目录 ./${CTYUN_DATA_DIR} 权限 (所有者UID:${PUID}, 组GID:${PGID})..."
    echo "      (下一步可能需要您输入 sudo 密码)"
    if sudo chown -R "${PUID}:${PGID}" "${CTYUN_DATA_DIR}"; then
        echo "   ✅ 目录权限设置成功。"
    else
        echo "❌ 错误：设置目录 ./${CTYUN_DATA_DIR} 权限失败。"
        echo "   请尝试手动执行以下命令:"
        echo "     sudo chown -R \"${PUID}:${PGID}\" \"$(pwd)/${CTYUN_DATA_DIR}\""
        echo "   如果权限未正确设置，容器可能无法写入数据，导致登录状态无法保存。"
        exit 1
    fi
}

# 函数：启动 Docker 服务
start_services() {
    echo " STEP 4: 启动 Docker 服务 (${CONTAINER_NAME})..."
    echo "   ℹ️  正在尝试停止并移除可能已存在的旧 ${CONTAINER_NAME} 服务 (使用 ${COMPOSE_CMD} down)..."
    ${COMPOSE_CMD} down > /dev/null 2>&1 # 静默执行

    echo "   ℹ️  正在启动 ${CONTAINER_NAME} 服务 (使用 ${COMPOSE_CMD} up -d)..."
    if ${COMPOSE_CMD} up -d; then
        echo "   ✅ 服务 ${CONTAINER_NAME} 尝试启动。"
    else
        echo "❌ 错误：启动 Docker Compose 服务失败。"
        echo "   请检查 Docker 和 Docker Compose 是否正确安装并运行，以及 ${DOCKER_COMPOSE_FILE} 文件内容。"
        echo "   您可以尝试手动执行 '${COMPOSE_CMD} up -d' 并查看错误信息。"
        exit 1
    fi

    # 检查容器是否真的在运行
    echo "   ℹ️  等待几秒钟让容器稳定..."
    sleep 8 # 等待时间可以根据服务器性能调整

    echo "   ℹ️  检查容器 ${CONTAINER_NAME} 状态..."
    if ${COMPOSE_CMD} ps | grep -q "${CONTAINER_NAME}" | grep -i "Up\|running"; then # 兼容不同 docker compose 版本输出
        echo "   ✅ 服务 ${CONTAINER_NAME} 已成功启动并正在运行。"
    else
        echo "⚠️  警告：${CONTAINER_NAME} 服务已执行启动命令，但容器可能未能成功运行或状态未知。"
        echo "   请使用以下命令查看容器的详细日志以排查问题："
        echo "     ${COMPOSE_CMD} logs ${CONTAINER_NAME}"
        echo "   或者持续跟踪日志："
        echo "     ${COMPOSE_CMD} logs -f ${CONTAINER_NAME}"
        # 不直接退出，给用户查看日志的机会
    fi
}

# 函数：显示后续步骤
show_next_steps() {
    echo ""
    echo "--------------------------------------------------"
    echo "🎉 部署脚本执行完毕！ 🎉"
    echo "--------------------------------------------------"
    echo "🔴 重要提示：首次运行需要扫码登录！ 🔴"
    echo "--------------------------------------------------"
    echo "请使用以下命令持续查看容器日志以获取二维码或扫码提示："
    echo ""
    echo "   ${COMPOSE_CMD} logs -f ${CONTAINER_NAME}"
    echo ""
    echo "扫描二维码后，项目将自动保活。"
    echo "后续重启服务器或 Docker 服务，${CONTAINER_NAME} 容器也会自动启动并登录。"
    echo "数据将保存在 $(pwd)/${CTYUN_DATA_DIR} 目录中。"
    echo "--------------------------------------------------"
}

# --- 主执行流程 ---
check_dependencies
create_docker_compose_file
create_data_directory
start_services
show_next_steps

exit 0

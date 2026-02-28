#!/bin/bash

# Orchids-2api 启动脚本
# 用法: ./run.sh [dev|build|start|stop|restart|status|logs]

set -e

PROJECT_NAME="orchids-server"
CONFIG_FILE="./config.json"
LOG_FILE="server.log"
PID_FILE=".orchids.pid"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Redis 是否运行
check_redis() {
    log_info "检查 Redis 连接..."

    REDIS_ADDR=$(grep -o '"redis_addr"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
    if [ -z "$REDIS_ADDR" ]; then
        REDIS_ADDR="127.0.0.1:6379"
    fi

    REDIS_HOST=$(echo "$REDIS_ADDR" | cut -d':' -f1)
    REDIS_PORT=$(echo "$REDIS_ADDR" | cut -d':' -f2)

    # 优先使用 redis-cli
    if command -v redis-cli &> /dev/null; then
        if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping &> /dev/null; then
            log_info "Redis 连接正常 ($REDIS_ADDR)"
            return 0
        fi
    else
        # 如果没有 redis-cli，尝试使用 nc 或 telnet 检查端口
        if command -v nc &> /dev/null; then
            if nc -z "$REDIS_HOST" "$REDIS_PORT" 2>/dev/null; then
                log_info "Redis 端口可达 ($REDIS_ADDR)"
                log_warn "建议安装 redis-cli 以进行完整检查"
                return 0
            fi
        elif command -v timeout &> /dev/null; then
            if timeout 1 bash -c "cat < /dev/null > /dev/tcp/$REDIS_HOST/$REDIS_PORT" 2>/dev/null; then
                log_info "Redis 端口可达 ($REDIS_ADDR)"
                log_warn "建议安装 redis-cli 以进行完整检查"
                return 0
            fi
        fi
    fi

    log_error "Redis 连接失败 ($REDIS_ADDR)"
    log_info "启动 Redis: docker run -d --name orchids-redis -p 6379:6379 redis:7"
    exit 1
}

# 检查配置文件
check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
    log_info "配置文件: $CONFIG_FILE"
}

# 开发模式（热重载）
dev() {
    log_info "启动开发模式..."
    check_config
    check_redis

    log_info "运行: go run ./cmd/server -config $CONFIG_FILE"
    go run ./cmd/server -config "$CONFIG_FILE"
}

# 编译
build() {
    log_info "编译项目..."
    go build -o "$PROJECT_NAME" ./cmd/server
    log_info "编译完成: $PROJECT_NAME"
}

# 启动服务
start() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            log_warn "服务已在运行 (PID: $PID)"
            return 0
        fi
    fi

    check_config
    check_redis

    if [ ! -f "$PROJECT_NAME" ]; then
        log_info "可执行文件不存在，开始编译..."
        build
    fi

    log_info "启动服务..."
    nohup ./"$PROJECT_NAME" -config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"

    sleep 1
    if ps -p "$PID" > /dev/null 2>&1; then
        log_info "服务启动成功 (PID: $PID)"
        log_info "查看日志: tail -f $LOG_FILE"
    else
        log_error "服务启动失败，查看日志: tail $LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi
}

# 停止服务
stop() {
    if [ ! -f "$PID_FILE" ]; then
        log_warn "PID 文件不存在，尝试通过进程名停止..."
        pkill -f "./$PROJECT_NAME -config" && log_info "服务已停止" || log_warn "未找到运行中的服务"
        return 0
    fi

    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        log_info "停止服务 (PID: $PID)..."
        kill "$PID"
        sleep 1

        if ps -p "$PID" > /dev/null 2>&1; then
            log_warn "强制停止服务..."
            kill -9 "$PID"
        fi

        log_info "服务已停止"
    else
        log_warn "服务未运行 (PID: $PID)"
    fi

    rm -f "$PID_FILE"
}

# 重启服务
restart() {
    log_info "重启服务..."
    stop
    sleep 1
    build
    start
}

# 查看状态
status() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            log_info "服务运行中 (PID: $PID)"

            PORT=$(grep -o '"port"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
            if [ -n "$PORT" ]; then
                log_info "监听端口: $PORT"
                if command -v lsof &> /dev/null; then
                    lsof -iTCP:"$PORT" -sTCP:LISTEN -n -P 2>/dev/null || true
                fi
            fi
            return 0
        else
            log_warn "PID 文件存在但进程未运行 (PID: $PID)"
            rm -f "$PID_FILE"
        fi
    else
        log_warn "服务未运行"
    fi

    # 检查是否有遗留进程
    if pgrep -f "./$PROJECT_NAME -config" > /dev/null; then
        log_warn "发现遗留进程:"
        ps aux | grep -v grep | grep "./$PROJECT_NAME -config"
    fi
}

# 查看日志
logs() {
    if [ ! -f "$LOG_FILE" ]; then
        log_error "日志文件不存在: $LOG_FILE"
        exit 1
    fi

    LINES=${1:-200}
    tail -n "$LINES" "$LOG_FILE"
}

# 显示帮助
usage() {
    cat << EOF
用法: $0 [命令]

命令:
  dev       开发模式（热重载，前台运行）
  build     编译项目
  start     启动服务（后台运行）
  stop      停止服务
  restart   重启服务（重新编译）
  status    查看服务状态
  logs      查看日志（默认最后 200 行）

示例:
  $0 dev              # 开发模式
  $0 start            # 启动服务
  $0 restart          # 重启服务
  $0 logs 500         # 查看最后 500 行日志

EOF
}

# 主逻辑
case "${1:-dev}" in
    dev)
        dev
        ;;
    build)
        build
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    logs)
        logs "${2:-200}"
        ;;
    *)
        usage
        exit 1
        ;;
esac

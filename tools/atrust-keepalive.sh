#!/usr/bin/env bash
# aTrust VPN 自动登录 + 会话保活（后台守护）
#
# 凭据只从 ~/.atrust_env 读取，本脚本不含任何密码。
# 密码与 TOTP 种子以 NUL 分隔经匿名管道交给 Python 子进程，只存在于该进程内存，
# 不出现在 argv / environ / 日志 / docker inspect / docker exec 命令行中。
#
# 用法:
#   tools/atrust-keepalive.sh              # 后台守护（本机 python + selenium）
#   tools/atrust-keepalive.sh --docker     # 后台守护（登录跑在 aTrust 容器内）
#   tools/atrust-keepalive.sh --status     # 查看状态 + 最近日志
#   tools/atrust-keepalive.sh --stop       # 停止守护进程
#   tools/atrust-keepalive.sh --foreground         # 前台调试（会一直跑，用 timeout 包起来）
#   tools/atrust-keepalive.sh --foreground-docker  # 同上，Docker 模式
#
# 行为约定:
#   * 保活只刷新当前已登录的那个标签页，不会反复弹出新的浏览器窗口。
#   * 需要人工验证（验证码 / 二次认证 / 扫码）时只响铃提醒，不重开窗口；
#     超时后保留页面原状，按下一次重试间隔再看。
#   * 响铃默认开启，`ATRUST_BEEP=0` 可关闭。
#
# 首次使用:
#   chmod 600 ~/.atrust_env
#   uv venv --python 3.13 .venv && uv pip install --python .venv/bin/python3 -r src/requirements.txt

set -Eeuo pipefail

# ------------------------------------------------------------------ 配置区

# 凭据文件（建议 chmod 600）
ENV_FILE="${ATRUST_ENV_FILE:-$HOME/.atrust_env}"

# 本机模式：项目源码目录（含 main.py）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${ATRUST_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../src" 2>/dev/null && pwd || printf '%s' "$SCRIPT_DIR/src")}"

# Docker 模式：容器名 / 容器内源码路径 / 容器内 session 目录
DOCKER_CONTAINER="${ATRUST_CONTAINER:-atrust}"
DOCKER_SRC="${ATRUST_DOCKER_SRC:-/opt/atrust-autologin}"
DOCKER_DATA_DIR="${ATRUST_DOCKER_DATA_DIR:-/root/.atrust-data}"

# 日志
LOG_FILE="${ATRUST_LOG_FILE:-$HOME/tmp/atrust_keepalive.log}"
LOG_MAX_KB="${ATRUST_LOG_MAX_KB:-5120}"    # 单文件轮转阈值（KB，默认 5 MiB）
LOG_KEEP=3

# 运行时文件（PID / 锁 / 临时 runner）
RUN_DIR="${ATRUST_RUN_DIR:-$HOME/tmp}"
PID_FILE="$RUN_DIR/atrust_keepalive.pid"
LOCK_FILE="$RUN_DIR/atrust_keepalive.lock"
MODE_FILE="$RUN_DIR/atrust_keepalive.mode"

# 会话 Cookie 目录（强制 0700）
DATA_DIR="${ATRUST_DATA_DIR:-$HOME/.atrust-data}"

# Python 解释器：显式指定 > 项目 .venv > 系统 python3
PROJECT_ROOT="$(cd "$PROJECT_DIR/.." 2>/dev/null && pwd || printf '%s' "$PROJECT_DIR")"

# 浏览器可执行文件：显式指定 > 系统 chrome/chromium > Playwright 缓存
BROWSER_PATH="${ATRUST_BROWSER_PATH:-}"

# 保活间隔（秒）
KEEPALIVE="${ATRUST_KEEPALIVE:-300}"

# 遇到验证码/扫码时在浏览器里等待的最长时间（秒）
LOGIN_TIMEOUT="${ATRUST_LOGIN_TIMEOUT:-120}"

# 是否允许浏览器交互：1=允许（VNC/桌面场景），0=遇人工验证直接失败重试
INTERACTIVE="${ATRUST_INTERACTIVE:-1}"

# 需要人工验证时是否响铃提醒：1=响（默认），0=静音
BEEP="${ATRUST_BEEP:-1}"

# 响铃之间的最小间隔（秒），避免重复报警
BEEP_INTERVAL="${ATRUST_BEEP_INTERVAL:-60}"

# 异常退出的重试退避（秒）
RETRY_MIN=10
RETRY_MAX=300

# ------------------------------------------------------------------ 日志

mkdir -p "$RUN_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true
umask 077

log()   { printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE"; }
info()  { log INFO "$1"; }
warn()  { log WARN "$1"; }
err()   { log ERROR "$1"; }
die()   { err "$1"; printf 'ERROR: %s\n' "$1" >&2; exit 1; }

rotate_logs() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || wc -c <"$LOG_FILE")
    (( size > LOG_MAX_KB * 1024 )) || return 0
    local i
    for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
        [[ -f "$LOG_FILE.$i" ]] && mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1"
    log INFO "日志已轮转"
}

# ------------------------------------------------------------------ 防重复执行

# 本脚本守护进程是否在跑（校验 cmdline，避免 PID 复用误判）
daemon_pid() {
    local pid cmd
    [[ -f "$PID_FILE" ]] || return 1
    read -r pid <"$PID_FILE" 2>/dev/null || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    [[ "$cmd" == *"${0##*/}"* ]] || return 1
    printf '%s\n' "$pid"
}

# 其它方式启动的登录自动化进程（容器内 / 手工 python main.py）。
# 严格匹配 python 调用 main.py 的命令行，避免误匹配到本脚本或 grep 自身。
foreign_login_process() {
    local pid cmd
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        # 排除本脚本自身及其子 shell
        case "$cmd" in
            *atrust-keepalive.sh*) continue ;;
        esac
        # 必须是 python 解释器直接跑 main.py
        case "$cmd" in
            *python*main.py*) printf '%s\n' "$cmd"; return 0 ;;
        esac
    done < <(pgrep -f 'main\.py' 2>/dev/null || true)
    return 1
}

# ------------------------------------------------------------------ 凭据

# 唯一读取凭据文件的地方；任何分支都不输出其内容。
load_credentials() {
    local quiet="${1:-}"
    [[ -r "$ENV_FILE" ]] || die "找不到可读的凭据文件: $ENV_FILE"

    local mode
    mode=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE" 2>/dev/null || echo unknown)
    case "$mode" in
        600|400) ;;
        *) warn "凭据文件权限为 $mode，建议: chmod 600 \"$ENV_FILE\"" ;;
    esac

    # shellcheck disable=SC1090
    if ! source "$ENV_FILE"; then
        die "凭据文件 $ENV_FILE 解析失败（语法错误），请检查其格式"
    fi

    [[ -n "${ATRUST_URL:-}"      ]] || die "ATRUST_URL 未设置"
    [[ -n "${ATRUST_USER:-}"     ]] || die "ATRUST_USER 未设置"
    [[ -n "${ATRUST_PASSWORD:-}" ]] || die "ATRUST_PASSWORD 未设置"

    # 取消 export：子进程 / /proc/<pid>/environ 里不会再出现密码或 TOTP 种子
    export -n ATRUST_PASSWORD
    export -n ATRUST_TOTP_KEY 2>/dev/null || true

    case "$ATRUST_URL" in
        https://*) ;;
        http://*)  warn "ATRUST_URL 使用 http://，密码将以明文提交" ;;
        *)         die "ATRUST_URL 必须是 http(s) URL" ;;
    esac

    if [[ "$quiet" != quiet ]]; then
        info "凭据已加载: $(printf '%s' "$ATRUST_URL" | sed -E 's#^([a-zA-Z]+://[^/]+).*#\1#') | 用户 $ATRUST_USER"
        if [[ -n "${ATRUST_TOTP_KEY:-}" ]]; then
            info "已启用 TOTP（种子经 stdin 传递，不落 argv / environ）"
        fi
    fi
}

# ------------------------------------------------------------------ Python runner

# 生成一次性 runner（0600）。敏感凭据只从 stdin 读，argv 只有普通配置项。
make_runner() {
    local path
    path="$(mktemp "$RUN_DIR/.runner.XXXXXX")"
    chmod 600 "$path"
    cat >"$path" <<'PY'
# aTrust 登录 runner：密码 / TOTP 种子从 stdin 以 NUL 分隔读入，
# 只存在于本进程内存，不进 argv / environ / 日志 / docker inspect。
import os
import signal
import sys

raw = sys.stdin.buffer.read()
parts = raw.split(b"\0")
del raw
if len(parts) < 2:
    print("ERROR: 未从 stdin 收到凭据", file=sys.stderr)
    raise SystemExit(4)

password = parts[0].decode("utf-8", "surrogateescape")
totp_key = parts[1].decode("utf-8", "surrogateescape")
del parts

if not password and not totp_key:
    print("ERROR: 未从 stdin 收到密码", file=sys.stderr)
    raise SystemExit(4)

conf = dict(arg.split("=", 1) for arg in sys.argv[1:] if "=" in arg)
allowed = {"portal_address", "username", "keepalive",
           "data_dir", "interactive", "login_timeout",
           "beep", "manual_beep_interval"}
kwargs = {k: v for k, v in conf.items() if k in allowed}

for key in ("keepalive", "login_timeout", "manual_beep_interval"):
    if key in kwargs:
        kwargs[key] = int(kwargs[key])
if "interactive" in kwargs:
    kwargs["interactive"] = kwargs["interactive"] == "1"
if "beep" in kwargs:
    kwargs["beep"] = kwargs["beep"] == "True"

kwargs["password"] = password
if totp_key:
    kwargs["totp_key"] = totp_key

# 浏览器路径由启动脚本探测后传入；为空则交给 Selenium 自行发现
browser = os.environ.pop("ATRUST_RUNNER_BROWSER", "")
if browser:
    kwargs["browser_path"] = browser

# 源码目录：本机模式由脚本经环境变量传入；Docker 模式 runner 就在 main.py 旁边
src = os.environ.pop("ATRUST_RUNNER_SRC", "") or os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, src)

try:
    import main as atrust
except Exception as exc:                                  # noqa: BLE001
    print("ERROR: 无法导入 main.py: %r" % (exc,), file=sys.stderr)
    raise SystemExit(3)


# 让 TERM/INT 走异常路径，main() 的 finally 才会执行 at.close()，
# 从而 driver.quit() 收掉 chromedriver 与浏览器，避免残留孤儿进程。
def _terminate(signum, frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, _terminate)
signal.signal(signal.SIGINT, _terminate)

atrust.main(**kwargs)
PY
    printf '%s\n' "$path"
}

# ------------------------------------------------------------------ 后端

docker_ready() {
    command -v docker >/dev/null 2>&1 || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DOCKER_CONTAINER" || return 1
    docker exec "$DOCKER_CONTAINER" test -f "$DOCKER_SRC/main.py" 2>/dev/null || return 1
}

# 容器若用 ATRUST_OPTS 传密码，docker inspect 可读明文 —— 告警。
warn_docker_env_password() {
    if docker exec "$DOCKER_CONTAINER" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null \
        | grep -q '^ATRUST_OPTS=.*--password'; then
        warn "容器 $DOCKER_CONTAINER 的 ATRUST_OPTS 含明文密码（docker inspect 可读），建议重建后改用本脚本"
        warn "容器自带 launcher 会与本脚本竞争，建议先停掉其 start-with-autologin-actual.sh"
    fi
}

child_pid=0
RUNNER_PATH=""
PYTHON=""

# 可被信号立即打断的 sleep：让 TERM 到达时马上跑 trap，而不是等 sleep 结束。
pause() {
    sleep "$1" &
    local sp=$!
    wait "$sp" 2>/dev/null || true
    kill "$sp" 2>/dev/null || true
    wait "$sp" 2>/dev/null || true
}

stop_child() {
    (( child_pid > 0 )) || return 0
    kill -0 "$child_pid" 2>/dev/null || return 0
    kill -TERM "$child_pid" 2>/dev/null || true
    local i
    for (( i = 0; i < 20; i++ )); do
        kill -0 "$child_pid" 2>/dev/null || return 0
        sleep 0.3
    done
    kill -KILL "$child_pid" 2>/dev/null || true
}

# 密码 / TOTP 种子以 NUL 分隔写进匿名管道，只进入子进程 stdin。
# 不经 argv、不经 environ、不落盘、不进日志。
build_secrets() {
    printf '%s\0%s\0' "$ATRUST_PASSWORD" "${ATRUST_TOTP_KEY:-}"
}

# 启动一次登录；main.py 内部的 keepalive 循环负责会话保活，进程退出即视为掉线。
run_login_once() {
    local mode="$1" rc=0
    local session_dir="$DATA_DIR"
    [[ "$mode" == docker ]] && session_dir="$DOCKER_DATA_DIR"

    local -a params=(
        "portal_address=$ATRUST_URL"
        "username=$ATRUST_USER"
        "keepalive=$KEEPALIVE"
        "data_dir=$session_dir"
        "interactive=$INTERACTIVE"
        "login_timeout=$LOGIN_TIMEOUT"
        "beep=$([ "$BEEP" = 1 ] && echo True || echo False)"
        "manual_beep_interval=$BEEP_INTERVAL"
    )
    if [[ "$mode" == docker ]]; then
        info "启动登录进程（容器 $DOCKER_CONTAINER，保活 ${KEEPALIVE}s）"
        if ! docker cp "$RUNNER_PATH" "$DOCKER_CONTAINER:$DOCKER_SRC/.runner.py" >>"$LOG_FILE" 2>&1; then
            err "无法把 runner 复制进容器"
            return 5
        fi
        build_secrets | docker exec -i "$DOCKER_CONTAINER" python3 "$DOCKER_SRC/.runner.py" "${params[@]}" \
                >>"$LOG_FILE" 2>&1 &
        child_pid=$!
    else
        info "启动登录进程（本机 ${PROJECT_DIR}，保活 ${KEEPALIVE}s）"
        build_secrets | ATRUST_RUNNER_SRC="$PROJECT_DIR" ATRUST_RUNNER_BROWSER="$BROWSER_PATH" \
                "$PYTHON" "$RUNNER_PATH" "${params[@]}" >>"$LOG_FILE" 2>&1 &
        child_pid=$!
    fi

    wait "$child_pid" || rc=$?
    child_pid=0
    return $rc
}

# ------------------------------------------------------------------ 主循环

daemon_loop() {
    local mode="${1:-local}"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        err "已有实例持有锁 $LOCK_FILE，退出"
        return 1
    fi

    RUNNER_PATH="$(make_runner)"

    info "=== aTrust 保活守护启动 (pid $$, 模式 $mode) ==="
    info "日志 $LOG_FILE"

    trap 'info "收到停止信号，正在退出"; stop_child; rm -f "${RUNNER_PATH:-}"; exit 0' TERM INT

    local backoff=$RETRY_MIN rc
    while :; do
        rotate_logs

        if [[ "$mode" == docker ]] && ! docker_ready; then
            warn "容器 $DOCKER_CONTAINER 不可用，30 秒后重试"
            pause 30
            continue
        fi

        rc=0
        run_login_once "$mode" || rc=$?

        case $rc in
            0)
                info "登录进程正常退出，5 秒后重新检查会话"
                backoff=$RETRY_MIN
                pause 5
                ;;
            130|137|143)
                info "登录进程被信号终止（code=$rc），退出"
                return 0
                ;;
            *)
                warn "登录进程异常退出（code=$rc），${backoff}s 后重试"
                pause "$backoff"
                backoff=$(( backoff * 2 ))
                (( backoff > RETRY_MAX )) && backoff=$RETRY_MAX
                ;;
        esac
    done
}

# ------------------------------------------------------------------ 解释器与浏览器

# 依次尝试：显式指定 / 项目 .venv / 系统 python3。返回可用的解释器路径。
resolve_python() {
    local candidate
    for candidate in \
        "${ATRUST_PYTHON:-}" \
        "$PROJECT_ROOT/.venv/bin/python3" \
        "$PROJECT_DIR/.venv/bin/python3" \
        "$(command -v python3 2>/dev/null || true)"
    do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c 'import selenium, pyotp, loguru, pydantic, fire' 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# 找一个可执行的 Chromium/Chrome。找到就导出给 runner，没找到则让 Selenium 自行处理。
resolve_browser() {
    [[ -n "$BROWSER_PATH" ]] && return 0
    local candidate
    for candidate in \
        "$(command -v google-chrome 2>/dev/null || true)" \
        "$(command -v google-chrome-stable 2>/dev/null || true)" \
        "$(command -v chromium 2>/dev/null || true)" \
        "$(command -v chromium-browser 2>/dev/null || true)" \
        "$(command -v microsoft-edge 2>/dev/null || true)" \
        $(ls -1d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | sort -V | tail -1)
    do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        BROWSER_PATH="$candidate"
        return 0
    done
    return 0
}

# ------------------------------------------------------------------ 预检

preflight() {
    local mode="$1"
    [[ "$LOG_MAX_KB" =~ ^[0-9]+$ ]] || die "ATRUST_LOG_MAX_KB 必须是整数（KB）"
    command -v flock >/dev/null 2>&1 || die "未安装 flock（util-linux）"

    if [[ "$mode" == docker ]]; then
        command -v docker >/dev/null 2>&1 || die "未安装 docker"
        docker_ready || die "容器 $DOCKER_CONTAINER 不可用（需运行中且含 $DOCKER_SRC/main.py）"
        warn_docker_env_password
    else
        [[ -f "$PROJECT_DIR/main.py" ]] || die "找不到 $PROJECT_DIR/main.py（用 ATRUST_PROJECT_DIR 指定）"

        PYTHON="$(resolve_python)" || {
            local sys_py
            sys_py="$(command -v python3 2>/dev/null || echo python3)"
            die "没有可用的 Python 环境（selenium/pyotp/loguru/pydantic/fire 缺失）。
请在项目根目录创建虚拟环境（不需要 sudo，也不碰系统 Python）:
  cd $PROJECT_ROOT && uv venv --python 3.13 .venv && uv pip install --python .venv/bin/python3 -r src/requirements.txt
若不用 uv: $sys_py -m venv .venv && .venv/bin/pip install -r src/requirements.txt
也可用 ATRUST_PYTHON=/path/to/python3 指定已有解释器。"
        }

        resolve_browser
        mkdir -p "$DATA_DIR"
        chmod 700 "$DATA_DIR"
    fi
}

# ------------------------------------------------------------------ 入口

case "${1:-}" in

    --status)
        if pid=$(daemon_pid); then
            printf '守护进程: 运行中 (pid %s, 模式 %s)\n' \
                "$pid" "$([[ -f "$MODE_FILE" ]] && cat "$MODE_FILE" || echo unknown)"
        else
            printf '守护进程: 未运行\n'
        fi
        printf '日志: %s\n' "$LOG_FILE"
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 8 "$LOG_FILE"
        fi
        exit 0
        ;;

    --stop)
        if pid=$(daemon_pid); then
            kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            kill -KILL "$pid" 2>/dev/null || true
            # 兜底：trap 可能来不及清理子进程 / runner
            pkill -f "$RUN_DIR/\.runner\." 2>/dev/null || true
            rm -f "$PID_FILE" "$MODE_FILE" "$RUN_DIR"/.runner.* 2>/dev/null || true
            info "守护进程已停止 (pid $pid)"
            printf '已停止 (pid %s)\n' "$pid"
        else
            printf '守护进程未运行\n'
        fi
        exit 0
        ;;

    --foreground)
        # 仅调试：会一直运行，请用 timeout 限制时间
        load_credentials
        preflight local
        daemon_loop local
        ;;

    --foreground-docker)
        load_credentials
        preflight docker
        daemon_loop docker
        ;;

    ""|--local|--docker)
        mode="local"
        if [[ "${1:-}" == "--docker" ]]; then
            mode="docker"
        fi

        if pid=$(daemon_pid); then
            printf '已有保活进程在运行 (pid %s)，本次退出。\n' "$pid"
            info "重复启动被拒绝，已有 pid $pid"
            exit 1
        fi
        if other=$(foreign_login_process); then
            printf '检测到已在运行的 aTrustLogin 进程，本次退出：\n  %s\n' "$other"
            info "重复启动被拒绝，已有登录进程"
            exit 1
        fi

        # 先在前台校验，配置错误立刻暴露，不留后台僵尸
        load_credentials quiet
        preflight "$mode"

        printf '%s\n' "$mode" >"$MODE_FILE"
        if [[ "$mode" == docker ]]; then
            target="--foreground-docker"
        else
            target="--foreground"
        fi

        setsid bash "${BASH_SOURCE[0]}" "$target" </dev/null >>"$LOG_FILE" 2>&1 &
        echo $! >"$PID_FILE"

        sleep 2
        if ! daemon_pid >/dev/null; then
            rm -f "$PID_FILE" "$MODE_FILE"
            die "守护进程启动失败，请查看 $LOG_FILE"
        fi

        printf '已在后台启动 (pid %s, 模式 %s)\n日志: %s\n' "$(cat "$PID_FILE")" "$mode" "$LOG_FILE"
        ;;

    -h|--help)
        sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
        ;;

    *)
        die "未知参数: $1（--help 查看用法）"
        ;;
esac

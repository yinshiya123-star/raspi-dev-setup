#!/usr/bin/env bash
#
# raspi-dev-setup.sh - 树莓派开发环境一键安装
# 内容: 美国时区 / Git / VS Code / C++ / Python / Java / Clash Verge Rev / Claude Code /
#       Claude Desktop / Pi-Apps 应用商店 / 一键切换美国节点命令 (clash-us)
# 系统: 64 位 Raspberry Pi OS (Bookworm 或更新版本)，建议桌面版
#
# 用法:
#   ./raspi-dev-setup.sh [选项]
#
# 选项:
#   --timezone <时区>   默认 America/Los_Angeles，也可用 America/New_York、
#                       America/Chicago、America/Denver 等
#   --proxy <地址>      安装过程使用的代理，例如 http://192.168.1.10:7890
#   --clash-deb <路径>  使用本地的 Clash Verge .deb，不从 GitHub 下载
#   --sub-file <路径>   从文件读取 Clash 订阅链接；不加时脚本会提示粘贴，可留空跳过
#   -h, --help          显示帮助

set -uo pipefail

TIMEZONE="America/Los_Angeles"
PROXY=""
CLASH_DEB=""
CLASH_PORT=7897 # Clash Verge Rev 默认混合端口
CLASH_REPO="clash-verge-rev/clash-verge-rev"
PROXY_HELPER="$HOME/.config/raspi-dev-proxy.sh"
CLAUDE_DESKTOP_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
SUB_FILE=""
SAVED_SUB_FILE="$HOME/.config/clash-us/subscription"

APT_OPTS=()
FAILED=()

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*" >&2; }
die() {
    printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
}

need_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "$1 需要一个参数"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --timezone)
        need_value "$@"
        TIMEZONE="$2"
        shift 2
        ;;
    --proxy)
        need_value "$@"
        PROXY="$2"
        shift 2
        ;;
    --clash-deb)
        need_value "$@"
        CLASH_DEB="$(realpath "$2")"
        [[ -f "$CLASH_DEB" ]] || die "找不到文件: $2"
        shift 2
        ;;
    --sub-file)
        need_value "$@"
        SUB_FILE="$(realpath "$2")"
        [[ -f "$SUB_FILE" ]] || die "找不到文件: $2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        die "未知选项: $1"
        ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || die "此脚本只能在树莓派 (Linux) 上运行"
[[ $EUID -ne 0 ]] || die "请用普通用户运行，不要加 sudo；需要 root 权限时脚本会自行调用"
command -v apt-get >/dev/null || die "未找到 apt-get，此脚本仅支持 Debian 系系统"
[[ "$(dpkg --print-architecture)" == "arm64" ]] ||
    die "需要 64 位系统 (arm64)，当前为 $(dpkg --print-architecture)。Claude Code 和 Clash Verge 都不支持 32 位，请刷写 64 位 Raspberry Pi OS"

if [[ -n "$PROXY" ]]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
    # sudo 默认会丢弃环境变量，所以直接传给 apt
    APT_OPTS=(-o "Acquire::http::Proxy=$PROXY" -o "Acquire::https::Proxy=$PROXY")
fi

apt_update() { sudo apt-get "${APT_OPTS[@]}" update; }
apt_install() { sudo apt-get "${APT_OPTS[@]}" install -y "$@"; }

# 每一步在子 shell 中运行：单步失败不影响其他步骤，最后统一汇总
run_step() {
    local name="$1"
    shift
    log "$name"
    (
        set -e
        "$@"
    )
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "$name 失败 (退出码 $rc)"
        FAILED+=("$name")
    fi
}

setup_timezone() {
    timedatectl list-timezones | grep -qx "$TIMEZONE" || {
        echo "无效的时区: $TIMEZONE" >&2
        return 1
    }
    sudo timedatectl set-timezone "$TIMEZONE"
    sudo timedatectl set-ntp true
    timedatectl | grep 'Time zone'
}

install_base_tools() {
    apt_update
    apt_install ca-certificates curl wget gnupg apt-transport-https git
}

install_cpp() {
    apt_install build-essential g++ gdb cmake ninja-build clang clang-format pkg-config
}

install_python() {
    apt_install python3 python3-pip python3-venv python3-dev
}

install_java() {
    apt_install default-jdk maven
}

install_vscode() {
    # Raspberry Pi OS 的软件源自带 code；其他系统改用微软官方源
    if ! apt-cache policy code | grep -q 'Candidate: [0-9]'; then
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
            gpg --dearmor | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
        echo "deb [arch=arm64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" |
            sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
        apt_update
    fi
    apt_install code
}

clash_deb_url() {
    curl -fsSL "https://api.github.com/repos/$CLASH_REPO/releases/latest" | python3 -c '
import json, sys
for asset in json.load(sys.stdin)["assets"]:
    if asset["name"].endswith("_arm64.deb"):
        print(asset["browser_download_url"])
        break
else:
    sys.exit("最新版本中没有 arm64 .deb")
'
}

install_clash_verge() {
    # tmp 不用 local：EXIT trap 在函数返回后才执行
    local deb="$CLASH_DEB"
    if [[ -z "$deb" ]]; then
        if dpkg -s clash-verge >/dev/null 2>&1; then
            echo "Clash Verge 已安装，跳过"
            return 0
        fi
        tmp="$(mktemp -d)"
        chmod 755 "$tmp"
        trap 'rm -rf "$tmp"' EXIT
        local url
        url="$(clash_deb_url)"
        deb="$tmp/$(basename "$url")"
        echo "下载 $url"
        curl -fL --retry 3 -o "$deb" "$url"
        chmod 644 "$deb"
    fi
    apt_install "$deb"
}

install_proxy_helper() {
    mkdir -p "$(dirname "$PROXY_HELPER")"
    cat >"$PROXY_HELPER" <<EOF
# 由 raspi-dev-setup.sh 生成
proxy_on() {
    local url="http://127.0.0.1:$CLASH_PORT"
    export http_proxy="\$url" https_proxy="\$url" all_proxy="\$url"
    export HTTP_PROXY="\$url" HTTPS_PROXY="\$url" ALL_PROXY="\$url"
    export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="localhost,127.0.0.1,::1"
    echo "代理已开启: \$url"
}
proxy_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
    echo "代理已关闭"
}
# 一键: 切到全局模式的美国节点，并让当前终端走代理
us_on() {
    clash-us && proxy_on
}
EOF
    local line="[ -f \"$PROXY_HELPER\" ] && . \"$PROXY_HELPER\""
    grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >>"$HOME/.bashrc"
}

install_claude_code() {
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # 先下载再执行，避免网络中断时运行半截脚本
    curl -fsSL --retry 3 -o "$tmp/install.sh" https://claude.ai/install.sh
    bash "$tmp/install.sh"

    # 官方安装器把程序放在 ~/.local/bin
    add_local_bin_to_path
}

add_local_bin_to_path() {
    local line='export PATH="$HOME/.local/bin:$PATH"'
    grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >>"$HOME/.bashrc"
}

install_claude_desktop() {
    local keyring=/usr/share/keyrings/claude-desktop-archive-keyring.asc fpr
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/key.asc" https://downloads.claude.ai/claude-desktop/key.asc
    fpr="$(gpg --show-keys --with-colons "$tmp/key.asc" | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$fpr" != "$CLAUDE_DESKTOP_KEY_FPR" ]]; then
        echo "Claude Desktop 签名密钥指纹不符: $fpr" >&2
        return 1
    fi
    sudo install -m 644 "$tmp/key.asc" "$keyring"
    echo "deb [arch=amd64,arm64 signed-by=$keyring] https://downloads.claude.ai/claude-desktop/apt/stable stable main" |
        sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
    apt_update
    apt_install claude-desktop
}

install_pi_apps() {
    if [[ -d "$HOME/pi-apps" ]]; then
        echo "Pi-Apps 已安装，跳过"
        return 0
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/install" https://raw.githubusercontent.com/Botspot/pi-apps/master/install
    # 官方用法是通过管道运行，安装器会据此判断目录，所以这里从 $HOME 经 stdin 执行
    cd "$HOME"
    bash <"$tmp/install"
}

install_clash_us() {
    mkdir -p "$HOME/.local/bin"
    cat >"$HOME/.local/bin/clash-us" <<'PYEOF'
#!/usr/bin/env python3
"""把 Clash Verge 切到全局模式，并选用延迟最低的美国节点。

用法: clash-us          启动 Clash Verge，没有节点时导入已保存的订阅，
                        然后切换到美国节点 + 全局模式
      clash-us --list   只列出美国节点及延迟，不做任何更改
      clash-us --rule   恢复规则模式
"""
import concurrent.futures
import glob
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

APP_DIR = os.path.expanduser(
    "~/.local/share/io.github.clash-verge-rev.clash-verge-rev"
)
SUB_FILE = os.path.expanduser("~/.config/clash-us/subscription")
START_TIMEOUT = 60
IMPORT_TIMEOUT = 90
TEST_URL = "http://www.gstatic.com/generate_204"
NON_NODE_TYPES = {
    "Selector", "URLTest", "Fallback", "LoadBalance", "Relay", "Smart",
    "Direct", "Reject", "RejectDrop", "Compatible", "Pass", "Dns",
}
# US/USA 区分大小写且不能紧贴字母，避免误中 Russia、Australia 等
US_NODE = re.compile(
    r"美国|美國|洛杉矶|洛杉磯|硅谷|矽谷|圣何塞|聖何塞|西雅图|西雅圖|纽约|紐約|芝加哥"
    r"|达拉斯|達拉斯|凤凰城|鳳凰城|🇺🇸|(?i:united\s*states)|(?<![A-Za-z])USA?(?![A-Za-z])"
)


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


class Api:
    def __init__(self, connect, secret=""):
        self.connect = connect
        self.secret = secret

    def call(self, method, path, body=None, timeout=10):
        conn = self.connect(timeout)
        headers = {"Content-Type": "application/json"}
        if self.secret:
            headers["Authorization"] = "Bearer " + self.secret
        try:
            conn.request(
                method, path, json.dumps(body) if body is not None else None, headers
            )
            resp = conn.getresponse()
            data = resp.read()
        finally:
            conn.close()
        if resp.status >= 400:
            raise RuntimeError("%s %s 返回 %d" % (method, path, resp.status))
        return json.loads(data) if data else {}


def read_controller_settings():
    """从配置读取 TCP 控制端口和密钥；只需要顶层的两个标量，不依赖 PyYAML"""
    settings = {}
    for name in ("clash-verge.yaml", "config.yaml"):
        try:
            with open(os.path.join(APP_DIR, name), encoding="utf-8") as f:
                text = f.read()
        except OSError:
            continue
        for key in ("external-controller", "secret"):
            match = re.search(
                r"^%s:[ \t]*['\"]?([^'\"\n#]*?)['\"]?[ \t]*(?:#.*)?$" % key, text, re.M
            )
            if match and match.group(1):
                settings.setdefault(key, match.group(1))
    return settings


def candidate_apis():
    if os.environ.get("CLASH_API"):
        url = urllib.parse.urlsplit(os.environ["CLASH_API"])
        yield Api(
            lambda t: http.client.HTTPConnection(url.hostname, url.port, timeout=t),
            os.environ.get("CLASH_SECRET", ""),
        )
        return

    settings = read_controller_settings()
    secret = settings.get("secret", "")
    if hasattr(os, "getuid"):
        sockets = [
            os.path.join(APP_DIR, "verge-mihomo.sock"),
            "/run/clash-verge-service/users/%d/verge-mihomo.sock" % os.getuid(),
        ] + glob.glob("/tmp/verge/verge-mihomo*.sock")
        for path in sockets:
            if os.path.exists(path):
                yield Api(lambda t, p=path: UnixConnection(p, t), secret)

    controller = settings.get("external-controller", "")
    if controller:
        host, _, port = controller.rpartition(":")
        if host in ("", "0.0.0.0"):
            host = "127.0.0.1"
        if port.isdigit():
            yield Api(
                lambda t: http.client.HTTPConnection(host, int(port), timeout=t), secret
            )


def try_connect():
    errors = []
    for api in candidate_apis():
        try:
            api.call("GET", "/version", timeout=3)
            return api, errors
        except (OSError, RuntimeError, ValueError) as e:
            errors.append(str(e))
    return None, errors


def connect_api(start=False):
    api, errors = try_connect()
    if api:
        return api
    if start and shutil.which("clash-verge"):
        if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            sys.exit("Clash Verge 未运行，且当前没有桌面会话。请在树莓派桌面的终端中运行。")
        print("正在启动 Clash Verge...")
        subprocess.Popen(
            ["clash-verge"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + START_TIMEOUT
        while time.monotonic() < deadline:
            time.sleep(2)
            api, errors = try_connect()
            if api:
                return api
    detail = "；".join(errors) if errors else "未找到控制接口"
    sys.exit("无法连接 Clash Verge (%s)。" % detail)


def has_nodes(api):
    proxies = api.call("GET", "/proxies")["proxies"]
    return any(
        proxies.get(name, {}).get("type") not in NON_NODE_TYPES
        for name in proxies.get("GLOBAL", {}).get("all", [])
    )


def read_saved_subscription():
    try:
        with open(SUB_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def import_subscription(api, url):
    link = "clash://install-config?name=%s&url=%s" % (
        urllib.parse.quote("订阅"),
        urllib.parse.quote(url, safe=""),
    )
    print("正在导入订阅...")
    try:
        opened = subprocess.run(["xdg-open", link], check=False).returncode == 0
    except OSError:
        opened = False
    if not opened:
        subprocess.run(["clash-verge", link], check=False)

    deadline = time.monotonic() + IMPORT_TIMEOUT
    while time.monotonic() < deadline:
        time.sleep(2)
        if has_nodes(api):
            return
    sys.exit(
        "等待 %d 秒后仍没有可用节点。请检查订阅链接和网络，"
        "或在 Clash Verge 的“配置”页选中导入的订阅后重试。" % IMPORT_TIMEOUT
    )


def measure(api, name):
    query = urllib.parse.urlencode({"timeout": 3000, "url": TEST_URL})
    path = "/proxies/%s/delay?%s" % (urllib.parse.quote(name, safe=""), query)
    try:
        return api.call("GET", path, timeout=6).get("delay") or None
    except (OSError, RuntimeError, ValueError):
        return None


def ranked_us_nodes(api):
    proxies = api.call("GET", "/proxies")["proxies"]
    names = [
        name
        for name in proxies.get("GLOBAL", {}).get("all", [])
        if proxies.get(name, {}).get("type") not in NON_NODE_TYPES and US_NODE.search(name)
    ]
    if not names:
        sys.exit("订阅中没有找到美国节点 (按节点名称匹配，如“美国”“US”)。")
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        delays = list(pool.map(lambda n: measure(api, n), names))
    return sorted(zip(names, delays), key=lambda x: (x[1] is None, x[1] or 0))


def exit_country(port):
    proxy = "http://127.0.0.1:%d" % port
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    )
    try:
        with opener.open("http://ipinfo.io/country", timeout=10) as resp:
            return resp.read().decode().strip()
    except OSError:
        return None


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg in ("-h", "--help"):
        print(__doc__)
        return 0
    if arg not in ("", "--list", "--rule"):
        print(__doc__)
        return 2

    api = connect_api(start=arg == "")

    # 只在没有节点时导入，避免每次运行都多出一份重复的订阅
    if arg == "" and not has_nodes(api):
        url = read_saved_subscription()
        if not url:
            sys.exit("Clash Verge 中没有节点，也没有保存的订阅 (%s)。" % SUB_FILE)
        import_subscription(api, url)

    if arg == "--rule":
        api.call("PATCH", "/configs", {"mode": "rule"})
        print("已恢复规则模式")
        return 0

    ranked = ranked_us_nodes(api)
    if arg == "--list":
        for name, delay in ranked:
            print("%8s  %s" % ("%d ms" % delay if delay else "超时", name))
        return 0

    name, delay = ranked[0]
    if not delay:
        # 全部不通时不做切换，保持原来可用的状态
        sys.exit("%d 个美国节点全部超时，未做任何更改。" % len(ranked))

    api.call("PUT", "/proxies/GLOBAL", {"name": name})
    api.call("PATCH", "/configs", {"mode": "global"})
    api.call("DELETE", "/connections")  # 旧连接不会自动换节点

    config = api.call("GET", "/configs")
    current = api.call("GET", "/proxies/GLOBAL").get("now")
    if config.get("mode", "").lower() != "global" or current != name:
        sys.exit("切换未生效: 模式=%s, 节点=%s" % (config.get("mode"), current))
    print("已切换: 全局模式 / %s (%d ms)" % (name, delay))

    port = config.get("mixed-port") or 7897
    country = exit_country(port)
    if country is None:
        print("[警告] 无法确认出口国家 (ipinfo.io 无响应)", file=sys.stderr)
    elif country != "US":
        print("[警告] 实际出口国家是 %s，不是美国，节点名称可能不准确" % country, file=sys.stderr)
        return 1
    else:
        print("出口国家已确认: US")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    chmod +x "$HOME/.local/bin/clash-us"
    add_local_bin_to_path
}

# 订阅链接等同于账号凭据：不走命令行参数，保存时只允许当前用户读取
save_subscription() {
    local url=""
    if [[ -n "$SUB_FILE" ]]; then
        url="$(tr -d '[:space:]' <"$SUB_FILE")"
    elif [[ -f "$SAVED_SUB_FILE" ]]; then
        echo "已有保存的订阅，沿用: $SAVED_SUB_FILE"
        return 0
    elif [[ -t 0 ]]; then
        read -rsp "粘贴 Clash 订阅链接 (输入不显示，留空跳过): " url
        echo
    fi
    [[ -n "$url" ]] || return 0
    [[ "$url" =~ ^https?:// ]] || die "订阅链接必须以 http:// 或 https:// 开头"
    mkdir -p "$(dirname "$SAVED_SUB_FILE")"
    (
        umask 077
        printf '%s\n' "$url" >"$SAVED_SUB_FILE"
    )
    chmod 600 "$SAVED_SUB_FILE"
}

switch_to_us_node() {
    "$HOME/.local/bin/clash-us"
}

show_version() {
    local label="$1"
    shift
    local version
    if version="$("$@" 2>&1 | head -n 1)" && command -v "$1" >/dev/null; then
        printf '  %-12s %s\n' "$label" "$version"
    else
        printf '  %-12s 未找到\n' "$label"
    fi
}

summary() {
    export PATH="$HOME/.local/bin:$PATH"
    log "安装结果"
    printf '  %-12s %s\n' "时区" "$(timedatectl show -p Timezone --value)"
    show_version "Git" git --version
    show_version "VS Code" code --version
    show_version "g++" g++ --version
    show_version "CMake" cmake --version
    show_version "Python" python3 --version
    show_version "Java" java --version
    show_version "Maven" mvn --version
    show_version "Claude Code" claude --version
    if dpkg -s claude-desktop >/dev/null 2>&1; then
        printf '  %-12s %s\n' "Claude App" "$(dpkg-query -W -f='${Version}' claude-desktop)"
    else
        printf '  %-12s 未找到\n' "Claude App"
    fi
    if [[ -d "$HOME/pi-apps" ]]; then
        printf '  %-12s %s\n' "Pi-Apps" "$HOME/pi-apps"
    else
        printf '  %-12s 未找到\n' "Pi-Apps"
    fi
    if dpkg -s clash-verge >/dev/null 2>&1; then
        printf '  %-12s %s\n' "Clash Verge" "$(dpkg-query -W -f='${Version}' clash-verge)"
    else
        printf '  %-12s 未找到\n' "Clash Verge"
    fi

    if [[ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]]; then
        warn "当前系统没有默认启动桌面。Clash Verge、VS Code、Claude Desktop 和 Pi-Apps 都是图形程序，需要桌面环境才能使用"
    fi

    cat <<EOF

后续步骤:
  1. 执行: source ~/.bashrc
  2. 如果没有在安装时填写订阅，把链接写入 $SAVED_SUB_FILE (权限设为 600)
  3. 在桌面终端执行: us_on  (自动启动 Clash、导入订阅、切到全局模式和延迟最低的美国节点，并让当前终端走代理)
  4. 执行: claude     (首次运行时按提示登录；桌面版在应用菜单打开 Claude)

其他命令:
  clash-us --list     查看美国节点及延迟
  clash-us --rule     恢复规则模式
  proxy_off           当前终端不再走代理
EOF

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        printf '\n\033[1;31m以下步骤失败: %s\033[0m\n' "${FAILED[*]}"
        echo "修复网络后可重新运行此脚本；如果无法直连 GitHub 或 claude.ai，请加 --proxy <地址>，Clash Verge 也可用 --clash-deb <路径> 安装。"
        exit 1
    fi
    printf '\n\033[1;32m全部完成。\033[0m\n'
}

save_subscription
sudo -v || die "需要 sudo 权限"

run_step "设置时区 ($TIMEZONE)" setup_timezone
run_step "安装基础工具和 Git" install_base_tools
run_step "安装 C++ 工具链" install_cpp
run_step "安装 Python" install_python
run_step "安装 Java" install_java
run_step "安装 VS Code" install_vscode
run_step "安装 Clash Verge Rev" install_clash_verge
run_step "配置代理快捷命令" install_proxy_helper
run_step "安装一键切换命令 clash-us" install_clash_us
run_step "安装 Claude Code" install_claude_code
run_step "安装 Claude Desktop" install_claude_desktop
run_step "安装 Pi-Apps 应用商店" install_pi_apps

if [[ -f "$SAVED_SUB_FILE" && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    run_step "切换到美国节点 (全局模式)" switch_to_us_node
elif [[ -f "$SAVED_SUB_FILE" ]]; then
    warn "当前不在桌面会话中 (例如通过 SSH 运行)，暂不切换节点。请在树莓派桌面的终端中执行 us_on"
fi

summary

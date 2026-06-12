#!/usr/bin/env sh
set -eu

REPO="mikumifa/biliTickerBuy"
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"

case "$UNAME_S:$UNAME_M" in
  Linux:x86_64|Linux:amd64)
    PLATFORM_KEY="linux_amd64"
    BINARY_NAME="biliTickerBuy"
    ;;
  Linux:aarch64|Linux:arm64)
    PLATFORM_KEY="linux_arm64"
    BINARY_NAME="biliTickerBuy"
    ;;
  Darwin:arm64|Darwin:aarch64)
    PLATFORM_KEY="macos_arm64"
    BINARY_NAME="biliTickerBuy"
    ;;
  Darwin:x86_64|Darwin:amd64)
    PLATFORM_KEY="macos_intel"
    BINARY_NAME="biliTickerBuy"
    ;;
  *)
    echo "当前平台暂不支持自动更新：$UNAME_S/$UNAME_M" >&2
    exit 1
    ;;
esac

INSTALL_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORK_DIR="$INSTALL_DIR/updates"
TEMP_ZIP="$WORK_DIR/update.zip"
TEMP_EXTRACT="$WORK_DIR/extract"
RELEASE_JSON_FILE="$WORK_DIR/release.json"
META_FILE="$WORK_DIR/release-meta.txt"

API_URL="https://api.github.com/repos/$REPO/releases/latest"
ENV_INSTALL_FILE="$INSTALL_DIR/.env.install"

CURRENT_BINARY="$INSTALL_DIR/$BINARY_NAME"
NEW_BINARY="$INSTALL_DIR/.${BINARY_NAME}.new.$$"
OLD_BINARY="$INSTALL_DIR/.${BINARY_NAME}.old.$$"

CURRENT_UPDATER="$INSTALL_DIR/update.sh"
NEW_UPDATER="$INSTALL_DIR/.update.sh.new.$$"

TMP_BASE="${TMPDIR:-/tmp}"
SWAP_SCRIPT="$TMP_BASE/biliTickerBuy-swap-$$.sh"

RELEASE_TAG=""
ASSET_URL=""
PACKAGE_BINARY=""
PACKAGE_DIR=""
HAS_UPDATER_UPDATE=0
UPDATE_SUCCEEDED=0

# ============================================================
# 通用函数
# ============================================================

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少必要命令：$1" >&2
    exit 1
  fi
}

print_network_help() {
  echo "请根据网络情况尝试取消 GH_PROXY，或更换其他可用加速前缀。" >&2
  echo "可在安装目录的 .env.install 中配置，例如：" >&2
  echo "GH_PROXY=https://gh-proxy.org" >&2
  echo "若要禁用代理，可执行：" >&2
  echo "GH_PROXY= ./update.sh" >&2
  echo "可用前缀可前往 https://ghproxy.link/ 查找。" >&2
}

cleanup_transient_files() {
  rm -f "$NEW_BINARY" 2>/dev/null || true

  if [ "$HAS_UPDATER_UPDATE" -eq 0 ]; then
    rm -f "$NEW_UPDATER" 2>/dev/null || true
  fi
}

cleanup_success_files() {
  rm -f "$TEMP_ZIP" 2>/dev/null || true
  rm -f "$RELEASE_JSON_FILE" 2>/dev/null || true
  rm -f "$META_FILE" 2>/dev/null || true
  rm -rf "$TEMP_EXTRACT" 2>/dev/null || true

  # 目录为空时删除；不为空则保留。
  rmdir "$WORK_DIR" 2>/dev/null || true
}

on_exit() {
  exit_code=$?

  cleanup_transient_files

  if [ "$UPDATE_SUCCEEDED" -eq 1 ]; then
    cleanup_success_files
  elif [ "$exit_code" -ne 0 ]; then
    echo "更新未完成，临时文件已保留在：$WORK_DIR" >&2
  fi

  exit "$exit_code"
}

trap on_exit EXIT HUP INT TERM

resolve_url() {
  input_url=$1

  case "${GH_PROXY:-}" in
    "")
      printf '%s\n' "$input_url"
      ;;
    */)
      printf '%s%s\n' "$GH_PROXY" "$input_url"
      ;;
    *)
      printf '%s/%s\n' "$GH_PROXY" "$input_url"
      ;;
  esac
}

http_get() {
  request_url=$1
  output_file=${2:-}

  if command -v curl >/dev/null 2>&1; then
    if [ -n "$output_file" ]; then
      curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --progress-bar \
        --header "User-Agent: biliTickerBuy-updater" \
        --header "Accept: application/octet-stream" \
        --output "$output_file" \
        "$request_url"
    else
      curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --silent \
        --show-error \
        --header "User-Agent: biliTickerBuy-updater" \
        "$request_url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$output_file" ]; then
      wget \
        --timeout=20 \
        --tries=3 \
        --output-document="$output_file" \
        --header="User-Agent: biliTickerBuy-updater" \
        --header="Accept: application/octet-stream" \
        "$request_url"
    else
      wget \
        --timeout=20 \
        --tries=3 \
        --quiet \
        --output-document=- \
        --header="User-Agent: biliTickerBuy-updater" \
        "$request_url"
    fi
  else
    echo "缺少必要命令：curl 或 wget" >&2
    return 1
  fi
}

request_release_json() {
  # GitHub API 优先直连，因为部分下载代理不支持 api.github.com。
  if http_get "$API_URL" "$RELEASE_JSON_FILE" 2>/dev/null; then
    return 0
  fi

  rm -f "$RELEASE_JSON_FILE"

  if [ -z "${GH_PROXY:-}" ]; then
    echo "获取 GitHub Release 信息失败：$API_URL" >&2
    return 1
  fi

  proxy_api_url="$(resolve_url "$API_URL")"

  echo "[biliTickerBuy] GitHub API 直连失败，正在尝试代理..."

  if http_get "$proxy_api_url" "$RELEASE_JSON_FILE"; then
    return 0
  fi

  rm -f "$RELEASE_JSON_FILE"
  echo "获取 GitHub Release 信息失败。" >&2
  return 1
}

parse_release_metadata() {
  rm -f "$META_FILE"

  if command -v jq >/dev/null 2>&1; then
    RELEASE_TAG="$(
      jq -r '.tag_name // empty' "$RELEASE_JSON_FILE"
    )"

    ASSET_URL="$(
      jq -r \
        --arg platform "_${PLATFORM_KEY}_" \
        '
          .assets[]
          | select(.name | contains($platform))
          | .browser_download_url
        ' \
        "$RELEASE_JSON_FILE" |
        head -n 1
    )"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$RELEASE_JSON_FILE" "$PLATFORM_KEY" "$META_FILE" <<'PY'
import json
import pathlib
import sys

json_path = pathlib.Path(sys.argv[1])
platform_key = sys.argv[2]
meta_path = pathlib.Path(sys.argv[3])

with json_path.open("r", encoding="utf-8") as file:
    release = json.load(file)

release_tag = release.get("tag_name") or ""
asset_url = ""

platform_marker = f"_{platform_key}_"

for asset in release.get("assets", []):
    name = asset.get("name") or ""
    if platform_marker in name:
        asset_url = asset.get("browser_download_url") or ""
        break

meta_path.write_text(
    f"RELEASE_TAG={release_tag}\nASSET_URL={asset_url}\n",
    encoding="utf-8",
)
PY

    RELEASE_TAG="$(
      sed -n 's/^RELEASE_TAG=//p' "$META_FILE" |
        head -n 1
    )"

    ASSET_URL="$(
      sed -n 's/^ASSET_URL=//p' "$META_FILE" |
        head -n 1
    )"
  else
    echo "解析 Release 信息需要 jq 或 python3，当前系统均未找到。" >&2
    return 1
  fi

  if [ -z "$RELEASE_TAG" ]; then
    echo "解析最新版本号失败。" >&2
    return 1
  fi

  if [ -z "$ASSET_URL" ]; then
    echo "最新版本中未找到当前平台 ${PLATFORM_KEY} 对应的更新包。" >&2
    return 1
  fi

  return 0
}

validate_zip() {
  zip_file=$1

  if [ ! -s "$zip_file" ]; then
    return 1
  fi

  unzip -tq "$zip_file" >/dev/null 2>&1
}

find_package_binary() {
  # 优先查找压缩包根目录。
  if [ -f "$TEMP_EXTRACT/$BINARY_NAME" ]; then
    printf '%s\n' "$TEMP_EXTRACT/$BINARY_NAME"
    return 0
  fi

  # 根目录不存在时递归查找。
  find "$TEMP_EXTRACT" \
    -type f \
    -name "$BINARY_NAME" \
    -print \
    2>/dev/null |
    head -n 1
}

replace_binary() {
  echo "[biliTickerBuy] 正在暂存新版程序..."

  rm -f "$NEW_BINARY" "$OLD_BINARY"

  if ! cp "$PACKAGE_BINARY" "$NEW_BINARY"; then
    echo "无法将新版程序复制到安装目录。" >&2
    return 1
  fi

  if ! chmod +x "$NEW_BINARY"; then
    rm -f "$NEW_BINARY"
    echo "无法为新版程序设置可执行权限。" >&2
    return 1
  fi

  # 先将旧程序移动为备份。
  if [ -e "$CURRENT_BINARY" ]; then
    if ! mv -f "$CURRENT_BINARY" "$OLD_BINARY"; then
      rm -f "$NEW_BINARY"
      echo "无法备份旧版程序：$CURRENT_BINARY" >&2
      echo "请检查目录权限。" >&2
      return 1
    fi
  fi

  # 再将新版程序切换到正式路径。
  if ! mv -f "$NEW_BINARY" "$CURRENT_BINARY"; then
    echo "无法启用新版程序，正在恢复旧版本..." >&2

    if [ -e "$OLD_BINARY" ]; then
      mv -f "$OLD_BINARY" "$CURRENT_BINARY" 2>/dev/null || true
    fi

    rm -f "$NEW_BINARY"
    return 1
  fi

  if [ ! -x "$CURRENT_BINARY" ]; then
    echo "新版程序替换后不可执行，正在恢复旧版本..." >&2

    rm -f "$CURRENT_BINARY"

    if [ -e "$OLD_BINARY" ]; then
      mv -f "$OLD_BINARY" "$CURRENT_BINARY" 2>/dev/null || true
    fi

    return 1
  fi

  rm -f "$OLD_BINARY"
  return 0
}

stage_updater_update() {
  package_updater="$PACKAGE_DIR/update.sh"

  if [ ! -f "$package_updater" ]; then
    return 0
  fi

  echo "[biliTickerBuy] 正在暂存新版更新脚本..."

  rm -f "$NEW_UPDATER"

  if ! cp "$package_updater" "$NEW_UPDATER"; then
    echo "警告：无法暂存新版 update.sh，但主程序已成功更新。" >&2
    return 0
  fi

  if ! chmod +x "$NEW_UPDATER"; then
    rm -f "$NEW_UPDATER"
    echo "警告：无法为新版 update.sh 设置可执行权限。" >&2
    return 0
  fi

  HAS_UPDATER_UPDATE=1
  return 0
}

create_swap_script() {
  cat >"$SWAP_SCRIPT" <<'SH'
#!/usr/bin/env sh
set -u

PARENT_PID=$1
STAGED_UPDATER=$2
TARGET_UPDATER=$3
SWAP_SCRIPT_PATH=$4

# 等待原 update.sh 完全退出。
while kill -0 "$PARENT_PID" 2>/dev/null; do
  sleep 1
done

if mv -f "$STAGED_UPDATER" "$TARGET_UPDATER"; then
  chmod +x "$TARGET_UPDATER" 2>/dev/null || true
else
  echo "[biliTickerBuy] update.sh 自更新失败。" >&2
  echo "暂存文件仍保留在：$STAGED_UPDATER" >&2
  rm -f "$SWAP_SCRIPT_PATH" 2>/dev/null || true
  exit 1
fi

rm -f "$SWAP_SCRIPT_PATH" 2>/dev/null || true
exit 0
SH

  chmod +x "$SWAP_SCRIPT"
}

launch_swap_script() {
  if [ "$HAS_UPDATER_UPDATE" -ne 1 ]; then
    return 0
  fi

  create_swap_script

  # 让辅助脚本脱离当前更新器运行。
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$SWAP_SCRIPT" \
      "$$" \
      "$NEW_UPDATER" \
      "$CURRENT_UPDATER" \
      "$SWAP_SCRIPT" \
      >/dev/null 2>&1 &
  else
    sh "$SWAP_SCRIPT" \
      "$$" \
      "$NEW_UPDATER" \
      "$CURRENT_UPDATER" \
      "$SWAP_SCRIPT" \
      >/dev/null 2>&1 &
  fi
}

# ============================================================
# 读取 GH_PROXY
#
# 优先级：
# 1. 当前 shell 中显式设置的 GH_PROXY，包括空字符串
# 2. .env.install 中的 GH_PROXY
# 3. 默认代理
# ============================================================

GH_PROXY_WAS_SET=0

if [ "${GH_PROXY+x}" = "x" ]; then
  GH_PROXY_WAS_SET=1
  GH_PROXY_VALUE=$GH_PROXY
else
  GH_PROXY_VALUE=""
fi

if [ "$GH_PROXY_WAS_SET" -eq 0 ] && [ -f "$ENV_INSTALL_FILE" ]; then
  ENV_PROXY_LINE="$(
    sed -n \
      's/^[[:space:]]*GH_PROXY[[:space:]]*=[[:space:]]*//p' \
      "$ENV_INSTALL_FILE" |
      tail -n 1 |
      tr -d '\r'
  )"

  if [ -n "$ENV_PROXY_LINE" ]; then
    GH_PROXY_VALUE=$ENV_PROXY_LINE

    # 去除常见的单引号或双引号。
    case "$GH_PROXY_VALUE" in
      \"*\")
        GH_PROXY_VALUE=$(
          printf '%s' "$GH_PROXY_VALUE" |
            sed 's/^"//;s/"$//'
        )
        ;;
      \'*\')
        GH_PROXY_VALUE=$(
          printf '%s' "$GH_PROXY_VALUE" |
            sed "s/^'//;s/'$//"
        )
        ;;
    esac

    GH_PROXY_WAS_SET=1
  fi
fi

if [ "$GH_PROXY_WAS_SET" -eq 1 ]; then
  GH_PROXY=$GH_PROXY_VALUE
else
  GH_PROXY="https://gh-proxy.org"
fi

export GH_PROXY

# ============================================================
# 环境检查
# ============================================================

require_cmd unzip
require_cmd find
require_cmd sed
require_cmd head
require_cmd mv
require_cmd cp
require_cmd chmod

if ! command -v curl >/dev/null 2>&1 &&
  ! command -v wget >/dev/null 2>&1; then
  echo "缺少必要命令：curl 或 wget" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1 &&
  ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 Release JSON 解析工具：请安装 jq 或 python3。" >&2
  exit 1
fi

# ============================================================
# 初始化临时目录
# ============================================================

mkdir -p "$WORK_DIR"

rm -f "$TEMP_ZIP"
rm -f "$RELEASE_JSON_FILE"
rm -f "$META_FILE"
rm -rf "$TEMP_EXTRACT"

mkdir -p "$TEMP_EXTRACT"

# ============================================================
# 获取最新版本信息
# ============================================================

echo "[biliTickerBuy] 正在检查 ${PLATFORM_KEY} 最新版本..."

if ! request_release_json; then
  print_network_help
  exit 1
fi

if [ ! -s "$RELEASE_JSON_FILE" ]; then
  echo "GitHub Release 返回内容为空。" >&2
  exit 1
fi

if ! parse_release_metadata; then
  exit 1
fi

echo "[biliTickerBuy] 最新版本：$RELEASE_TAG"

DOWNLOAD_URL="$(resolve_url "$ASSET_URL")"

# ============================================================
# 下载更新包
# ============================================================

echo "[biliTickerBuy] 正在下载 ${RELEASE_TAG}..."

if ! http_get "$DOWNLOAD_URL" "$TEMP_ZIP"; then
  echo "下载失败：$DOWNLOAD_URL" >&2
  rm -f "$TEMP_ZIP"
  print_network_help
  exit 1
fi

if [ ! -s "$TEMP_ZIP" ]; then
  echo "下载到的更新包为空：$TEMP_ZIP" >&2
  rm -f "$TEMP_ZIP"
  exit 1
fi

# ============================================================
# 验证 ZIP
# ============================================================

echo "[biliTickerBuy] 正在验证更新包..."

if ! validate_zip "$TEMP_ZIP"; then
  echo "更新包不是有效的 ZIP 文件。" >&2
  echo "下载地址：$DOWNLOAD_URL" >&2
  echo "这通常是 GitHub 代理返回了错误页面。" >&2
  rm -f "$TEMP_ZIP"
  exit 1
fi

# ============================================================
# 解压
# ============================================================

echo "[biliTickerBuy] 正在解压更新包..."

if ! unzip -oq "$TEMP_ZIP" -d "$TEMP_EXTRACT"; then
  echo "更新包解压失败：$TEMP_ZIP" >&2
  exit 1
fi

# ============================================================
# 查找程序文件
# ============================================================

PACKAGE_BINARY="$(find_package_binary)"

if [ -z "$PACKAGE_BINARY" ] || [ ! -f "$PACKAGE_BINARY" ]; then
  echo "解压后的更新包中缺少 $BINARY_NAME 可执行文件。" >&2
  echo "更新包内容如下：" >&2
  find "$TEMP_EXTRACT" -maxdepth 4 -print >&2
  exit 1
fi

PACKAGE_DIR="$(dirname "$PACKAGE_BINARY")"

echo "[biliTickerBuy] 找到程序文件：$PACKAGE_BINARY"

# ============================================================
# 替换主程序
# ============================================================

echo "[biliTickerBuy] 正在替换本地程序..."

if ! replace_binary; then
  echo "替换主程序失败。" >&2
  exit 1
fi

# ============================================================
# 暂存 update.sh
#
# 不直接覆盖当前正在执行的脚本。
# 当前脚本退出后，由辅助脚本完成替换。
# ============================================================

stage_updater_update

# ============================================================
# 安装默认配置
#
# 不覆盖用户已有的 .env.install。
# ============================================================

if [ ! -f "$ENV_INSTALL_FILE" ] &&
  [ -f "$PACKAGE_DIR/.env.install" ]; then
  if ! cp "$PACKAGE_DIR/.env.install" "$ENV_INSTALL_FILE"; then
    echo "警告：无法安装默认 .env.install。" >&2
  fi
else
  if [ -f "$ENV_INSTALL_FILE" ]; then
    echo "[biliTickerBuy] 保留现有 .env.install 配置。"
  fi
fi

# ============================================================
# 启动更新器自更新辅助脚本
# ============================================================

if [ "$HAS_UPDATER_UPDATE" -eq 1 ]; then
  echo "[biliTickerBuy] update.sh 将在当前脚本退出后完成替换。"
  launch_swap_script
fi

UPDATE_SUCCEEDED=1

echo
echo "[biliTickerBuy] 已更新到 ${RELEASE_TAG}。"
echo "请手动重新启动程序。"

exit 0
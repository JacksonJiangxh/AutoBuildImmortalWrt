# ============================================================================
# 自动识别 ImageBuilder 原始软件源并切换到 USTC 镜像
#
# 注意：ImmortalWrt 25.12+ 使用 APK 包管理器，文件名是 repositories（无后缀）
#       24.10 及以下使用 OPKG，文件名是 repositories.conf
# 本脚本自动检测两种文件名
# ============================================================================

echo "========================================"
echo "Switching repositories to USTC mirror"
echo "========================================"

# 自动检测 repositories 文件名（APK 模式: repositories，OPKG 模式: repositories.conf）
if [ -f "repositories" ]; then
    REPO_FILE="repositories"
elif [ -f "repositories.conf" ]; then
    REPO_FILE="repositories.conf"
else
    echo "ERROR: Neither 'repositories' nor 'repositories.conf' found!"
    echo "Files in current directory:"
    ls -la
    exit 1
fi

echo ">>> Detected repository file: $REPO_FILE"

echo ">>> Original repositories:"
cat "$REPO_FILE"
echo ""

# 尝试从原始源中提取 releases 路径部分
# 从文件中提取第一个 URL（兼容 OPKG 的 "src/gz name URL" 和 APK 的纯 URL 格式）
ORIGINAL_URL=$(grep -oP 'https?://[^[:space:]]+' "$REPO_FILE" | head -1 | tr -d '[:space:]')

if [ -z "$ORIGINAL_URL" ]; then
    echo "ERROR: No repository URL found in $REPO_FILE"
    cat "$REPO_FILE"
    exit 1
fi

echo ">>> First repository URL: $ORIGINAL_URL"

# 提取 /releases/ 之后的版本号（如 25.12.0）
RELEASE_VERSION=$(echo "$ORIGINAL_URL" | grep -oP '/releases/\K[^/]+' | head -1)

if [ -z "$RELEASE_VERSION" ]; then
    echo "ERROR: Could not extract release version from URL: $ORIGINAL_URL"
    exit 1
fi

echo ">>> Detected release version: $RELEASE_VERSION"

# 提取 /releases/ 之后、/targets/ 或 /packages/ 之前的架构路径
# 例如从 .../releases/25.12.0/targets/x86/64/packages/... 提取 targets 及之后
# 或从 .../releases/25.12.0/packages/x86_64/base/... 提取 packages 及之后
RELEASE_SUFFIX=$(echo "$ORIGINAL_URL" | grep -oP '/releases/[^/]+/\K.*' | head -1)

if [ -z "$RELEASE_SUFFIX" ]; then
    echo "ERROR: Could not extract path suffix from URL: $ORIGINAL_URL"
    exit 1
fi

echo ">>> Path suffix pattern: $RELEASE_SUFFIX"

# USTC ImmortalWrt 镜像基础 URL
USTC_BASE="https://mirrors.ustc.edu.cn/immortalwrt/releases/${RELEASE_VERSION}"

echo ">>> New USTC base URL: $USTC_BASE"
echo ""

# 策略：识别并替换所有已知的原始域名/前缀，统一指向 USTC
# 支持的原始源格式：
#   1. https://downloads.immortalwrt.org/releases/...
#   2. https://mirrors.vsean.net/openwrt/releases/...
#   3. 其他 https://xxx/.../releases/版本号/... 格式

# 方法：用 sed 提取每条 URL 的 /releases/版本号/ 之后的部分，
# 然后拼接 USTC 前缀

NEW_REPO_FILE="${REPO_FILE}.new"
> "$NEW_REPO_FILE"

while IFS= read -r line; do
    # 跳过空行和注释
    if [ -z "$line" ] || echo "$line" | grep -q '^[[:space:]]*#'; then
        echo "$line" >> "$NEW_REPO_FILE"
        continue
    fi

    # 从行中提取 URL（兼容 OPKG 的 "src/gz name URL" 和 APK 的纯 URL 格式）
    EXTRACTED_URL=$(echo "$line" | grep -oP 'https?://[^[:space:]]+' | head -1)

    if [ -n "$EXTRACTED_URL" ]; then
        # 提取 /releases/版本号/ 之后的部分
        SUFFIX=$(echo "$EXTRACTED_URL" | grep -oP '/releases/[^/]+/\K.*' | head -1)
        if [ -n "$SUFFIX" ]; then
            NEW_URL="${USTC_BASE}/${SUFFIX}"
            # 替换行中的 URL
            echo "$line" | sed "s|${EXTRACTED_URL}|${NEW_URL}|" >> "$NEW_REPO_FILE"
        else
            # 无法识别，保留原样
            echo "$line" >> "$NEW_REPO_FILE"
        fi
    else
        # 无 URL 行，保留原样
        echo "$line" >> "$NEW_REPO_FILE"
    fi
done < "$REPO_FILE"

# 替换原文件
mv "$NEW_REPO_FILE" "$REPO_FILE"

echo ">>> Updated repositories:"
cat "$REPO_FILE"
echo ""
echo "✅ Repositories switched to USTC mirror successfully."

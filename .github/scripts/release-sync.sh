#!/bin/bash
set -e

PLATFORM="${1}"
REPO="${2}"
TOKEN="${3}"
TAG_NAME="${4}"
VERSION="${5}"
BUILD_TIME="${6}"
GITHUB_REPO="${7}"

if [ "$PLATFORM" != "gitee" ]; then
  echo "::warning::仅支持 Gitee 平台，跳过 $PLATFORM"
  exit 0
fi

PLATFORM_NAME="Gitee"
API_BASE="https://gitee.com/api/v5"

echo "::group::📤 上传到 $PLATFORM_NAME"

if [ -z "$TOKEN" ]; then
  echo "::warning::未配置 Gitee Token，跳过发布"
  exit 0
fi

echo "平台: $PLATFORM_NAME"
echo "仓库: https://gitee.com/$REPO"
echo "标签: $TAG_NAME"

# 检查 Release 是否已存在
echo "检查 Release 是否已存在..."
releases=$(curl -s "$API_BASE/repos/$REPO/releases?access_token=$TOKEN&page=1&per_page=20")
existing_release=$(echo "$releases" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag)')

if [ -n "$existing_release" ]; then
  echo "::notice::检测到已存在 Release $TAG_NAME，将直接上传文件"
  skip_create=true
else
  skip_create=false
fi

# 获取最新 commit（如果需要创建）
if [ "$skip_create" = false ]; then
  echo "获取最新 commit..."
  commit_info=$(curl -s "$API_BASE/repos/$REPO/commits?access_token=$TOKEN&page=1&per_page=1")
  latest_commit=$(echo "$commit_info" | jq -r '.[0].sha // empty')

  if [ -z "$latest_commit" ] || [ "$latest_commit" = "null" ]; then
    echo "  ⚠️  无法获取 commit，将不指定 ref"
    latest_commit=""
  else
    echo "  ✓ commit: ${latest_commit:0:8}..."
  fi
fi

# 准备 Release 内容
RELEASE_BODY="## 📦 包含文件
- **APK 格式**：ImmortalWrt 主线
- **IPK 格式**：ImmortalWrt 24.10

## 📌 版本信息
- 上游版本: $TAG_NAME
- 构建时间: $BUILD_TIME

## 📥 完整说明
https://github.com/$GITHUB_REPO/releases/tag/$TAG_NAME"

# 创建 Release
if [ "$skip_create" = false ]; then
  echo "创建 Release..."

  if [ -n "$latest_commit" ]; then
    release_payload=$(jq -n \
      --arg token "$TOKEN" \
      --arg tag "$TAG_NAME" \
      --arg name "luci-app-tailscale $VERSION" \
      --arg body "$RELEASE_BODY" \
      --arg ref "$latest_commit" \
      '{access_token: $token, tag_name: $tag, name: $name, body: $body, target_commitish: $ref, prerelease: false}')
  else
    release_payload=$(jq -n \
      --arg token "$TOKEN" \
      --arg tag "$TAG_NAME" \
      --arg name "luci-app-tailscale $VERSION" \
      --arg body "$RELEASE_BODY" \
      '{access_token: $token, tag_name: $tag, name: $name, body: $body, prerelease: false}')
  fi
  
  release_response=$(echo "$release_payload" | curl -s -X POST "$API_BASE/repos/$REPO/releases" \
    -H "Content-Type: application/json" -d @-)
  
  release_id=$(echo "$release_response" | jq -r '.id // empty')
  
  if [ -z "$release_id" ]; then
    echo "::error::Gitee Release 创建失败"
    echo "$release_response" | jq '.'
    exit 1
  fi
  
  echo "✓ 创建 Gitee Release 成功，ID: $release_id"
else
  # 获取现有 release 的 ID
  release_id=$(echo "$existing_release" | jq -r '.id')
  echo "✓ 使用现有 Release，ID: $release_id"
fi

# 上传文件
echo "上传文件..."
uploaded=0
failed=0

for file in out/*; do
  if [ ! -f "$file" ]; then
    continue
  fi
  
  filename=$(basename "$file")
  echo "  上传: $filename"
  
  upload_response=$(curl -s -X POST \
    "$API_BASE/repos/$REPO/releases/$release_id/attach_files" \
    -F "access_token=$TOKEN" \
    -F "file=@$file")
  
  if echo "$upload_response" | jq -e '.browser_download_url' > /dev/null 2>&1; then
    echo "    ✓ 成功"
    uploaded=$((uploaded + 1))
  else
    error_msg=$(echo "$upload_response" | jq -r '.message // .error_message // "未知错误"')
    echo "    ✗ 失败: $error_msg"
    failed=$((failed + 1))
  fi
done

if [ $uploaded -gt 0 ]; then
  echo "::notice::✅ $PLATFORM_NAME Release 发布完成（成功 $uploaded 个，失败 $failed 个）"
  echo "::notice::🔗 https://gitee.com/$REPO/releases/tag/$TAG_NAME"
else
  echo "::warning::⚠️  所有文件上传失败，但 Release 已创建"
  echo "::notice::请访问 https://gitee.com/$REPO/releases/tag/$TAG_NAME 手动上传"
fi

echo "::endgroup::"

#!/bin/bash
set -e

REPO="${1}"           # 仓库路径 (user/repo)
TOKEN="${2}"          # Access Token
TAG_NAME="${3}"       # 版本标签
VERSION="${4}"        # 版本号
BUILD_TIME="${5}"     # 构建时间
GITHUB_REPO="${6}"    # GitHub 仓库路径

PLATFORM_NAME="Gitee"
API_BASE="https://gitee.com/api/v5"

echo "::group::📤 上传到 $PLATFORM_NAME"

if [ -z "$TOKEN" ]; then
  echo "::warning::未配置 GITEE_TOKEN，跳过发布"
  exit 0
fi

echo "仓库: https://gitee.com/$REPO"
echo "标签: $TAG_NAME"

# 检查 Release 是否已存在
echo "检查 Release 是否已存在..."
releases=$(curl -s "$API_BASE/repos/$REPO/releases?access_token=$TOKEN&page=1&per_page=20")
existing_release=$(echo "$releases" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag)')

if [ -n "$existing_release" ]; then
  echo "::notice::Gitee 上已存在 Release $TAG_NAME"
  release_id=$(echo "$existing_release" | jq -r '.id // empty')
  
  if [ -n "$release_id" ]; then
    echo "使用已存在的 Release ID: $release_id"
    skip_create=true
  else
    echo "::warning::已存在的 Release 没有 ID，跳过发布"
    exit 0
  fi
else
  skip_create=false
fi

# 获取最新 commit（如果需要创建）
if [ "$skip_create" = false ]; then
  echo "获取最新 commit..."
  commit_info=$(curl -s "$API_BASE/repos/$REPO/commits?access_token=$TOKEN&page=1&per_page=1")
  latest_commit=$(echo "$commit_info" | jq -r '.[0].sha // empty')

  if [ -z "$latest_commit" ] || [ "$latest_commit" = "null" ]; then
    echo "::error::无法获取最新 commit，请确保仓库有提交记录"
    exit 1
  fi

  echo "  ✓ commit: ${latest_commit:0:8}..."
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
  
  release_payload=$(jq -n \
    --arg token "$TOKEN" \
    --arg tag "$TAG_NAME" \
    --arg name "luci-app-tailscale $VERSION" \
    --arg body "$RELEASE_BODY" \
    --arg ref "$latest_commit" \
    '{
      access_token: $token,
      tag_name: $tag,
      name: $name,
      body: $body,
      target_commitish: $ref,
      prerelease: false
    }')
  
  release_response=$(echo "$release_payload" | curl -s -X POST "$API_BASE/repos/$REPO/releases" \
    -H "Content-Type: application/json" \
    -d @-)
  
  release_id=$(echo "$release_response" | jq -r '.id // empty')
  
  if [ -z "$release_id" ]; then
    echo "::error::创建 Gitee Release 失败"
    echo "$release_response" | jq '.'
    exit 1
  fi
  
  echo "✓ 创建 Release 成功，ID: $release_id"
fi

# 上传文件
echo "上传文件到 Release ID: $release_id ..."
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
    error_msg=$(echo "$upload_response" | jq -r '.message // "未知错误"')
    echo "    ✗ 失败: $error_msg"
    failed=$((failed + 1))
  fi
done

if [ $uploaded -gt 0 ]; then
  echo "::notice::✅ Gitee Release 发布完成（成功 $uploaded 个，失败 $failed 个）"
  echo "::notice::🔗 https://gitee.com/$REPO/releases/tag/$TAG_NAME"
else
  echo "::error::❌ 所有文件上传失败"
  exit 1
fi

echo "::endgroup::"

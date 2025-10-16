#!/bin/bash
set -e

PLATFORM="${1}"
REPO="${2}"
TOKEN="${3}"
TAG_NAME="${4}"
VERSION="${5}"
BUILD_TIME="${6}"
GITHUB_REPO="${7}"

case "$PLATFORM" in
  gitee)
    PLATFORM_NAME="Gitee"
    API_BASE="https://gitee.com/api/v5"
    AUTH_HEADER="access_token=$TOKEN"
    AUTH_TYPE="query"
    ;;
  gitcode)
    PLATFORM_NAME="GitCode"
    API_BASE="https://gitcode.com/api/v5"
    AUTH_HEADER="PRIVATE-TOKEN: $TOKEN"
    AUTH_TYPE="header"
    ;;
  *)
    echo "::error::未知平台: $PLATFORM"
    exit 1
    ;;
esac

echo "::group::📤 上传到 $PLATFORM_NAME"

if [ -z "$TOKEN" ]; then
  echo "::warning::未配置 ${PLATFORM_NAME} Token，跳过发布"
  exit 0
fi

echo "平台: $PLATFORM_NAME"
echo "仓库: https://${PLATFORM}.com/$REPO"
echo "标签: $TAG_NAME"

# 检查 Release 是否已存在
echo "检查 Release 是否已存在..."
if [ "$AUTH_TYPE" = "header" ]; then
  releases=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO/releases?page=1&per_page=20")
else
  releases=$(curl -s "$API_BASE/repos/$REPO/releases?$AUTH_HEADER&page=1&per_page=20")
fi

tag_exists=$(echo "$releases" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag) | .tag_name' | head -1)

if [ "$tag_exists" = "$TAG_NAME" ]; then
  echo "::notice::$PLATFORM_NAME 上已存在 Release $TAG_NAME，跳过发布"
  exit 0
fi

# 获取最新 commit
echo "获取最新 commit..."
if [ "$PLATFORM" = "gitee" ]; then
  commit_info=$(curl -s "$API_BASE/repos/$REPO/commits?$AUTH_HEADER&page=1&per_page=1")
  latest_commit=$(echo "$commit_info" | jq -r '.[0].sha // empty')

elif [ "$PLATFORM" = "gitcode" ]; then
  # 先获取项目信息得到默认分支
  project_info=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO")
  default_branch=$(echo "$project_info" | jq -r '.default_branch // "main"')
  echo "  默认分支: $default_branch"
  
  # 获取分支的最新 commit
  branch_info=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO/branches/$default_branch")
  latest_commit=$(echo "$branch_info" | jq -r '.commit.id // empty')
  
  # 降级方案：直接获取 commits 列表
  if [ -z "$latest_commit" ] || [ "$latest_commit" = "null" ]; then
    commits=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO/commits?page=1&per_page=1")
    latest_commit=$(echo "$commits" | jq -r '.[0].id // empty')
  fi
fi

if [ -z "$latest_commit" ] || [ "$latest_commit" = "null" ]; then
  echo "  ⚠️  无法获取 commit，将不指定 ref"
  latest_commit=""
else
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
echo "创建 Release..."

if [ "$PLATFORM" = "gitee" ]; then
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

elif [ "$PLATFORM" = "gitcode" ]; then
  # GitCode: 同时发送 body 和 description
  if [ -n "$latest_commit" ]; then
    release_payload=$(jq -n \
      --arg tag "$TAG_NAME" \
      --arg name "luci-app-tailscale $VERSION" \
      --arg body "$RELEASE_BODY" \
      --arg ref "$latest_commit" \
      '{tag_name: $tag, name: $name, body: $body, description: $body, ref: $ref}')
  else
    release_payload=$(jq -n \
      --arg tag "$TAG_NAME" \
      --arg name "luci-app-tailscale $VERSION" \
      --arg body "$RELEASE_BODY" \
      '{tag_name: $tag, name: $name, body: $body, description: $body}')
  fi
  
  echo "::group::📝 请求 JSON"
  echo "$release_payload" | jq '.'
  echo "::endgroup::"
  
  release_response=$(echo "$release_payload" | curl -s -X POST "$API_BASE/repos/$REPO/releases" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d @-)
fi

echo "::group::📥 API 响应"
echo "$release_response" | jq '.' 2>/dev/null || echo "$release_response"
echo "::endgroup::"

release_id=$(echo "$release_response" | jq -r '.id // empty')

if [ -z "$release_id" ]; then
  echo "::error::创建 $PLATFORM_NAME Release 失败"
  exit 1
fi

echo "✓ 创建 Release 成功，ID: $release_id"

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
  
  if [ "$PLATFORM" = "gitee" ]; then
    upload_response=$(curl -s -X POST \
      "$API_BASE/repos/$REPO/releases/$release_id/attach_files" \
      -F "access_token=$TOKEN" \
      -F "file=@$file")
    success_field="browser_download_url"
  elif [ "$PLATFORM" = "gitcode" ]; then
    upload_response=$(curl -s -X POST \
      "$API_BASE/repos/$REPO/releases/$release_id/attach_files" \
      -H "$AUTH_HEADER" \
      -F "file=@$file")
    success_field="url"
  fi
  
  if echo "$upload_response" | jq -e ".$success_field" > /dev/null 2>&1; then
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
  echo "::notice::🔗 https://${PLATFORM}.com/$REPO/releases/tag/$TAG_NAME"
else
  echo "::error::❌ 所有文件上传失败"
  exit 1
fi

echo "::endgroup::"

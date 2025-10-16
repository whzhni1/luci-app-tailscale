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
  if [ "$PLATFORM" = "gitee" ]; then
    commit_info=$(curl -s "$API_BASE/repos/$REPO/commits?$AUTH_HEADER&page=1&per_page=1")
    latest_commit=$(echo "$commit_info" | jq -r '.[0].sha // empty')

  elif [ "$PLATFORM" = "gitcode" ]; then
    project_info=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO")
    default_branch=$(echo "$project_info" | jq -r '.default_branch // "main"')
    echo "  默认分支: $default_branch"
    
    branch_info=$(curl -s -H "$AUTH_HEADER" "$API_BASE/repos/$REPO/branches/$default_branch")
    latest_commit=$(echo "$branch_info" | jq -r '.commit.id // empty')
    
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
    
    release_id=$(echo "$release_response" | jq -r '.id // empty')
    
    if [ -z "$release_id" ]; then
      echo "::error::Gitee Release 创建失败"
      echo "$release_response" | jq '.'
      exit 1
    fi
    
    echo "✓ 创建 Gitee Release 成功，ID: $release_id"

  elif [ "$PLATFORM" = "gitcode" ]; then
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
    
    echo "::group::📥 API 响应"
    echo "$release_response" | jq '.' 2>/dev/null || echo "$release_response"
    echo "::endgroup::"
    
    # GitCode 不返回 id，使用 tag_name 作为标识
    response_tag=$(echo "$release_response" | jq -r '.tag_name // empty')
    
    if [ "$response_tag" = "$TAG_NAME" ]; then
      echo "✓ 创建 GitCode Release 成功（使用 tag: $TAG_NAME）"
      release_id=""  # GitCode 不需要 ID
    else
      echo "::error::GitCode Release 创建失败"
      exit 1
    fi
  fi
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
  
  if [ "$PLATFORM" = "gitee" ]; then
    # Gitee 使用 release_id
    upload_response=$(curl -s -X POST \
      "$API_BASE/repos/$REPO/releases/$release_id/attach_files" \
      -F "access_token=$TOKEN" \
      -F "file=@$file")
    success_field="browser_download_url"
    
  elif [ "$PLATFORM" = "gitcode" ]; then
    # GitCode 使用 tag_name（尝试两种可能的 API）
    
    # 方法 1：先尝试通过 tag 上传
    upload_response=$(curl -s -X POST \
      "$API_BASE/repos/$REPO/releases/tags/$TAG_NAME/attach_files" \
      -H "$AUTH_HEADER" \
      -F "file=@$file")
    
    # 方法 2：如果方法 1 失败，尝试直接上传
    if ! echo "$upload_response" | jq -e '.url' > /dev/null 2>&1; then
      upload_response=$(curl -s -X POST \
        "$API_BASE/repos/$REPO/releases/$TAG_NAME/attach_files" \
        -H "$AUTH_HEADER" \
        -F "file=@$file")
    fi
    
    success_field="url"
  fi
  
  if echo "$upload_response" | jq -e ".$success_field" > /dev/null 2>&1; then
    echo "    ✓ 成功"
    uploaded=$((uploaded + 1))
  else
    error_msg=$(echo "$upload_response" | jq -r '.message // .error_message // "未知错误"')
    echo "    ✗ 失败: $error_msg"
    
    echo "::group::上传响应详情"
    echo "$upload_response" | jq '.' 2>/dev/null || echo "$upload_response"
    echo "::endgroup::"
    
    failed=$((failed + 1))
  fi
done

if [ $uploaded -gt 0 ]; then
  echo "::notice::✅ $PLATFORM_NAME Release 发布完成（成功 $uploaded 个，失败 $failed 个）"
  echo "::notice::🔗 https://${PLATFORM}.com/$REPO/releases/tag/$TAG_NAME"
else
  echo "::warning::⚠️  所有文件上传失败，但 Release 已创建"
  echo "::notice::请访问 https://${PLATFORM}.com/$REPO/releases/tag/$TAG_NAME 手动上传"
fi

echo "::endgroup::"

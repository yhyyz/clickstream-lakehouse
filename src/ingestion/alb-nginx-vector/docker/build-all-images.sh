#!/bin/bash

set -e

# 默认配置变量
DEFAULT_REGION="us-east-1"
DEFAULT_NGINX_IMAGE_NAME="clickstream-nginx-vector-optimized"
DEFAULT_VECTOR_IMAGE_NAME="clickstream-vector-optimized"

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

构建并推送 nginx 和 vector Docker 镜像到 Amazon ECR

选项:
    -r, --region REGION              AWS 区域 (默认: $DEFAULT_REGION)
    -n, --nginx-image NAME           Nginx 镜像名称 (默认: $DEFAULT_NGINX_IMAGE_NAME)
    -v, --vector-image NAME          Vector 镜像名称 (默认: $DEFAULT_VECTOR_IMAGE_NAME)
    -h, --help                       显示此帮助信息

示例:
    $0                                                    # 使用默认参数
    $0 -r us-west-2                                      # 指定区域
    $0 -r us-west-2 -n my-nginx -v my-vector            # 指定所有参数

EOF
}

# 解析命令行参数
REGION="$DEFAULT_REGION"
NGINX_IMAGE_NAME="$DEFAULT_NGINX_IMAGE_NAME"
VECTOR_IMAGE_NAME="$DEFAULT_VECTOR_IMAGE_NAME"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -n|--nginx-image)
            NGINX_IMAGE_NAME="$2"
            shift 2
            ;;
        -v|--vector-image)
            VECTOR_IMAGE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "错误: 未知参数 $1"
            echo "使用 $0 --help 查看帮助信息"
            exit 1
            ;;
    esac
done

# 验证参数
if [[ -z "$REGION" || -z "$NGINX_IMAGE_NAME" || -z "$VECTOR_IMAGE_NAME" ]]; then
    echo "错误: 所有参数都不能为空"
    show_help
    exit 1
fi

# 获取账户ID和构建ECR URI
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NGINX_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${NGINX_IMAGE_NAME}"
VECTOR_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${VECTOR_IMAGE_NAME}"

echo "开始构建和推送镜像到ECR..."
echo "Account ID: $ACCOUNT_ID"
echo "Region: $REGION"
echo "Nginx ECR URI: $NGINX_ECR_URI"
echo "Vector ECR URI: $VECTOR_ECR_URI"

# 检查并创建ECR仓库的函数
create_ecr_repository_if_not_exists() {
    local repo_name=$1
    local region=$2
    
    echo "检查ECR仓库: $repo_name"
    
    # 检查仓库是否存在
    if aws ecr describe-repositories --repository-names "$repo_name" --region "$region" >/dev/null 2>&1; then
        echo "ECR仓库 '$repo_name' 已存在，跳过创建"
    else
        echo "ECR仓库 '$repo_name' 不存在，正在创建..."
        aws ecr create-repository \
            --repository-name "$repo_name" \
            --region "$region" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
        echo "ECR仓库 '$repo_name' 创建成功"
    fi
}

# 创建ECR仓库（如果不存在）
echo "检查并创建ECR仓库..."
create_ecr_repository_if_not_exists "$NGINX_IMAGE_NAME" "$REGION"
create_ecr_repository_if_not_exists "$VECTOR_IMAGE_NAME" "$REGION"

# 获取ECR登录token
echo "登录到ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# 构建Nginx Docker镜像
echo "构建Nginx Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) --build-arg PLATFORM_ARG=linux/amd64 -t $NGINX_IMAGE_NAME -f nginx/Dockerfile ./nginx

# 构建Vector Docker镜像
echo "构建Vector Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) --build-arg PLATFORM_ARG=linux/amd64 -t $VECTOR_IMAGE_NAME -f vector/Dockerfile ./vector

# 标记镜像
echo "标记镜像..."
docker tag $NGINX_IMAGE_NAME:latest $NGINX_ECR_URI:latest
docker tag $VECTOR_IMAGE_NAME:latest $VECTOR_ECR_URI:latest

# 推送镜像到ECR
echo "推送Nginx镜像到ECR..."
docker push $NGINX_ECR_URI:latest

echo "推送Vector镜像到ECR..."
docker push $VECTOR_ECR_URI:latest

echo "所有镜像构建和推送完成！"
echo "Nginx ECR镜像URI: $NGINX_ECR_URI:latest"
echo "Vector ECR镜像URI: $VECTOR_ECR_URI:latest"

# 保存镜像信息到临时文件
echo "保存镜像信息..."
cat > ../tmp/docker-images-info.json << EOF
{
  "nginx_image_uri": "$NGINX_ECR_URI:latest",
  "vector_image_uri": "$VECTOR_ECR_URI:latest",
  "region": "$REGION",
  "account_id": "$ACCOUNT_ID",
  "build_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "镜像信息已保存到 ../tmp/docker-images-info.json"

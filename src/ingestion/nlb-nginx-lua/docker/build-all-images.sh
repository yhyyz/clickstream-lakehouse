#!/bin/bash

set -e

# 默认配置变量
DEFAULT_REGION="us-east-1"
DEFAULT_COLLECT_IMAGE_NAME="clickstream-openresty-lua-msk-optimized"
DEFAULT_FLUENTBIT_IMAGE_NAME="custom-fluent-bit-optimized"

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

构建并推送 nginx-for-lua 和 fluent-bit Docker 镜像到 Amazon ECR

选项:
    -r, --region REGION              AWS 区域 (默认: $DEFAULT_REGION)
    -c, --collect-image NAME         采集应用镜像名称 (默认: $DEFAULT_COLLECT_IMAGE_NAME)
    -f, --fluentbit-image NAME       Fluent Bit 镜像名称 (默认: $DEFAULT_FLUENTBIT_IMAGE_NAME)
    -h, --help                       显示此帮助信息

示例:
    $0                                                    # 使用默认参数
    $0 -r us-west-2                                      # 指定区域
    $0 -r us-west-2 -c my-collect-app -f my-fluentbit   # 指定所有参数

EOF
}

# 解析命令行参数
REGION="$DEFAULT_REGION"
COLLECT_IMAGE_NAME="$DEFAULT_COLLECT_IMAGE_NAME"
FLUENTBIT_IMAGE_NAME="$DEFAULT_FLUENTBIT_IMAGE_NAME"

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -c|--collect-image)
            COLLECT_IMAGE_NAME="$2"
            shift 2
            ;;
        -f|--fluentbit-image)
            FLUENTBIT_IMAGE_NAME="$2"
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
if [[ -z "$REGION" || -z "$COLLECT_IMAGE_NAME" || -z "$FLUENTBIT_IMAGE_NAME" ]]; then
    echo "错误: 所有参数都不能为空"
    show_help
    exit 1
fi

# 获取账户ID和构建ECR URI
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
COLLECT_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${COLLECT_IMAGE_NAME}"
FLUENTBIT_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${FLUENTBIT_IMAGE_NAME}"

echo "开始构建和推送镜像到ECR..."
echo "Account ID: $ACCOUNT_ID"
echo "Region: $REGION"
echo "Collect App ECR URI: $COLLECT_ECR_URI"
echo "Fluent Bit ECR URI: $FLUENTBIT_ECR_URI"

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
create_ecr_repository_if_not_exists "$COLLECT_IMAGE_NAME" "$REGION"
create_ecr_repository_if_not_exists "$FLUENTBIT_IMAGE_NAME" "$REGION"

# 获取ECR登录token
echo "登录到ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# 构建采集应用Docker镜像
echo "构建采集应用Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) -t $COLLECT_IMAGE_NAME -f nginx-for-lua/Dockerfile ./nginx-for-lua

# 构建Fluent Bit Docker镜像
echo "构建Fluent Bit Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) -t $FLUENTBIT_IMAGE_NAME -f fluent-bit/Dockerfile.fluentbit ./fluent-bit

# 标记镜像
echo "标记镜像..."
docker tag $COLLECT_IMAGE_NAME:latest $COLLECT_ECR_URI:latest
docker tag $FLUENTBIT_IMAGE_NAME:latest $FLUENTBIT_ECR_URI:latest

# 推送镜像到ECR
echo "推送采集应用镜像到ECR..."
docker push $COLLECT_ECR_URI:latest

echo "推送Fluent Bit镜像到ECR..."
docker push $FLUENTBIT_ECR_URI:latest

echo "所有镜像构建和推送完成！"
echo "采集应用ECR镜像URI: $COLLECT_ECR_URI:latest"
echo "Fluent Bit ECR镜像URI: $FLUENTBIT_ECR_URI:latest"

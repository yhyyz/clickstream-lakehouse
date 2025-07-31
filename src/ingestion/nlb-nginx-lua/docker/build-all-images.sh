#!/bin/bash

set -e

# 配置变量
REGION="us-east-1"
COLLECT_IMAGE_NAME="clickstream-openresty-lua-msk-optimized"
FLUENTBIT_IMAGE_NAME="custom-fluent-bit-optimized"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
COLLECT_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${COLLECT_IMAGE_NAME}"
FLUENTBIT_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${FLUENTBIT_IMAGE_NAME}"

echo "开始构建和推送镜像到ECR..."
echo "Account ID: $ACCOUNT_ID"
echo "Collect App ECR URI: $COLLECT_ECR_URI"
echo "Fluent Bit ECR URI: $FLUENTBIT_ECR_URI"


# 创建ECR仓库（如果不存在）
echo "创建ECR仓库..."
aws ecr create-repository \
    --repository-name $COLLECT_IMAGE_NAME \
    --region $REGION \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    2>/dev/null || echo "采集应用ECR仓库已存在或创建失败，继续..."

aws ecr create-repository \
    --repository-name $FLUENTBIT_IMAGE_NAME \
    --region $REGION \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    2>/dev/null || echo "Fluent Bit ECR仓库已存在或创建失败，继续..."

# 获取ECR登录token
echo "登录到ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# 构建采集应用Docker镜像
echo "构建采集应用Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) -t $COLLECT_IMAGE_NAME -f Dockerfile .

# 构建Fluent Bit Docker镜像
echo "构建Fluent Bit Docker镜像..."
docker build --build-arg CACHEBUST=$(date +%s) -t $FLUENTBIT_IMAGE_NAME -f Dockerfile.fluentbit .

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

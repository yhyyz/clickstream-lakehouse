#!/bin/bash

set -e

REGION="us-east-1"
CLUSTER_NAME="clickstream-cluster"
TASK_FAMILY="clickstream-task-optimized"
SERVICE_NAME="clickstream-optimized-service"

# 创建S3存储桶用于数据存储
echo "创建S3存储桶..."
aws s3 mb s3://clickstream-logs-bucket-${ACCOUNT_ID} --region $REGION 2>/dev/null || echo "S3存储桶已存在或创建失败，继续..."

echo "开始部署ECS任务和服务..."

# 创建CloudWatch日志组
echo "创建CloudWatch日志组..."
aws logs create-log-group \
    --log-group-name "/ecs/clickstream-optimized" \
    --region $REGION \
    2>/dev/null || echo "日志组已存在，继续..."

# 检查集群是否存在，如果不存在则创建
echo "检查并创建ECS集群..."
aws ecs describe-clusters --clusters $CLUSTER_NAME --region $REGION >/dev/null 2>&1 || {
    echo "创建ECS集群: $CLUSTER_NAME"
    aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $REGION
}

# 注册任务定义
echo "注册ECS任务定义..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file://task-definition.json \
    --region $REGION \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo "任务定义已注册: $TASK_DEF_ARN"

# 检查服务是否已存在
echo "检查服务是否存在..."
if aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION >/dev/null 2>&1; then
    echo "更新现有服务..."
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 4 \
        --region $REGION
else
    echo "创建新服务..."
    aws ecs create-service \
        --cli-input-json file://service-definition.json \
        --region $REGION
fi

echo "等待服务稳定..."
aws ecs wait services-stable \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $REGION

echo "ECS服务部署完成！"

# 获取服务状态
echo "获取服务状态..."
aws ecs describe-services \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $REGION \
    --query 'services[0].{ServiceName:serviceName,Status:status,RunningCount:runningCount,DesiredCount:desiredCount}'

#!/bin/bash

set -e

REGION="us-east-1"
VPC_ID="vpc-00667484e3a766975"  # 使用ECS任务所在的默认VPC
CLUSTER_NAME="clickstream-cluster"
SERVICE_NAME="clickstream-optimized-service"
NLB_NAME="clickstream-nlb-optimized"
TARGET_GROUP_NAME="clickstream-tg-optimized"

echo "开始创建NLB和目标组..."

# 创建目标组
echo "创建目标组..."
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name $TARGET_GROUP_NAME \
    --protocol TCP \
    --port 8802 \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-protocol TCP \
    --health-check-port 8802 \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

echo "目标组已创建: $TARGET_GROUP_ARN"

# 创建网络负载均衡器 - 使用默认VPC的公有子网
echo "创建网络负载均衡器..."
NLB_ARN=$(aws elbv2 create-load-balancer \
    --name $NLB_NAME \
    --scheme internet-facing \
    --type network \
    --subnets subnet-0b25c566633959782 subnet-0ba4b834e204c4e2c subnet-0c0e54eb5d9088404 \
    --region $REGION \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

echo "NLB已创建: $NLB_ARN"

# 获取NLB的DNS名称
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $NLB_ARN \
    --region $REGION \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo "NLB DNS名称: $NLB_DNS"

# 创建监听器
echo "创建监听器..."
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $NLB_ARN \
    --protocol TCP \
    --port 8802 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
    --region $REGION \
    --query 'Listeners[0].ListenerArn' \
    --output text)

echo "监听器已创建: $LISTENER_ARN"

# 启用跨AZ负载均衡
echo "启用跨AZ负载均衡..."
aws elbv2 modify-load-balancer-attributes \
    --load-balancer-arn $NLB_ARN \
    --attributes Key=load_balancing.cross_zone.enabled,Value=true \
    --region $REGION

# 等待NLB变为活动状态
echo "等待NLB变为活动状态..."
aws elbv2 wait load-balancer-available \
    --load-balancer-arns $NLB_ARN \
    --region $REGION

# 将ECS服务与目标组关联
echo "将ECS服务与目标组关联..."
aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --load-balancers targetGroupArn=$TARGET_GROUP_ARN,containerName=clickstream-container,containerPort=8802 \
    --region $REGION

echo "NLB部署完成！"
echo "NLB DNS名称: $NLB_DNS"
echo "访问URL: http://$NLB_DNS:8802"

# 保存NLB信息到文件
cat > nlb-info.txt << EOF
NLB名称: $NLB_NAME
NLB ARN: $NLB_ARN
NLB DNS: $NLB_DNS
目标组ARN: $TARGET_GROUP_ARN
访问URL: http://$NLB_DNS:8802
EOF

echo "NLB信息已保存到 nlb-info.txt"

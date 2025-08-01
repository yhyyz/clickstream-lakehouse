#!/bin/bash

# Clickstream Lakehouse 部署示例脚本
# 这个脚本展示了如何使用deploy-all.sh进行部署

set -e

echo "=========================================="
echo "Clickstream Lakehouse 部署示例"
echo "=========================================="

# 示例配置 - 请根据您的环境修改这些值
EXAMPLE_S3_BUCKET="my-clickstream-lakehouse-bucket"
EXAMPLE_MSK_CLUSTER="my-msk-cluster"
EXAMPLE_REGION="us-east-1"

echo "本示例将使用以下配置："
echo "  S3存储桶: $EXAMPLE_S3_BUCKET"
echo "  MSK集群: $EXAMPLE_MSK_CLUSTER"
echo "  AWS区域: $EXAMPLE_REGION"
echo "  VPC ID: 将从MSK集群自动获取"
echo ""

echo "请确保："
echo "1. 您已经创建了上述S3存储桶"
echo "2. MSK集群已经存在并正在运行"
echo "3. AWS CLI已配置正确的权限"
echo "4. Docker已安装并运行"
echo ""

read -p "是否继续执行示例部署? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "部署已取消"
    exit 0
fi

echo "=========================================="
echo "开始部署..."
echo "=========================================="

# 执行完整部署
./deploy-all.sh \
  --s3-bucket "$EXAMPLE_S3_BUCKET" \
  --msk-cluster "$EXAMPLE_MSK_CLUSTER" \
  --region "$EXAMPLE_REGION" \
  --desired-count 2 \
  --worker-count 4

echo "=========================================="
echo "部署完成!"
echo "=========================================="

echo "接下来您可以："
echo "1. 检查ECS服务状态"
echo "2. 获取NLB DNS名称进行测试"
echo "3. 验证MSK连接器状态"
echo "4. 查看生成的信息文件"

echo ""
echo "快速验证命令："
echo "# 检查ECS服务"
echo "aws ecs describe-services --cluster clickstream-cluster --services clickstream-optimized-service --region $EXAMPLE_REGION"
echo ""
echo "# 获取NLB DNS"
echo "aws elbv2 describe-load-balancers --names clickstream-optimized-service-nlb --query 'LoadBalancers[0].DNSName' --output text --region $EXAMPLE_REGION"
echo ""
echo "# 检查MSK连接器"
echo "aws kafkaconnect list-connectors --region $EXAMPLE_REGION"

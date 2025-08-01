#!/bin/bash

# Clickstream Lakehouse 数据流测试脚本
# 用于验证部署后的数据链路是否正常工作

set -e

# 默认配置
DEFAULT_REGION="us-east-1"
DEFAULT_NLB_NAME="clickstream-optimize-nlb"
DEFAULT_PROJECT="app_logs"

# 显示帮助信息
show_help() {
    cat << EOF
Clickstream Lakehouse 数据流测试脚本

用法: $0 [选项]

选项:
    -r, --region REGION          AWS区域 (默认: $DEFAULT_REGION)
    -n, --nlb-name NAME          NLB名称 (默认: $DEFAULT_NLB_NAME)
    -p, --project PROJECT        项目名称/MSK主题名称 (默认: $DEFAULT_PROJECT)
    -c, --count COUNT            发送测试消息数量 (默认: 10)
    -i, --interval SECONDS       消息发送间隔 (默认: 1秒)
    -h, --help                   显示此帮助信息

示例:
    $0                                    # 使用默认参数发送10条测试消息
    $0 -c 50 -i 0.5                     # 发送50条消息，间隔0.5秒
    $0 -r us-west-2 -n my-nlb           # 指定区域和NLB名称
    $0 -p my_topic -c 20                # 指定项目名称和消息数量

注意:
    - 数据会先进行base64编码后发送
    - 请求会包含project header，值为指定的项目名称

EOF
}

# 解析命令行参数
REGION="$DEFAULT_REGION"
NLB_NAME="$DEFAULT_NLB_NAME"
PROJECT="$DEFAULT_PROJECT"
MESSAGE_COUNT=10
INTERVAL=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -n|--nlb-name)
            NLB_NAME="$2"
            shift 2
            ;;
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        -c|--count)
            MESSAGE_COUNT="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
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

echo "=========================================="
echo "Clickstream Lakehouse 数据流测试"
echo "=========================================="
echo "AWS区域: $REGION"
echo "NLB名称: $NLB_NAME"
echo "项目名称: $PROJECT"
echo "消息数量: $MESSAGE_COUNT"
echo "发送间隔: ${INTERVAL}秒"
echo "数据编码: Base64"
echo "=========================================="

# 获取NLB DNS名称
echo "获取NLB DNS名称..."
NLB_DNS=$(aws elbv2 describe-load-balancers \
  --names "$NLB_NAME" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$REGION" 2>/dev/null)

if [[ -z "$NLB_DNS" || "$NLB_DNS" == "None" ]]; then
    echo "错误: 无法找到NLB '$NLB_NAME' 或获取其DNS名称"
    echo "请确保NLB已正确部署并且名称正确"
    exit 1
fi

echo "NLB DNS: $NLB_DNS"
echo "测试端点: http://$NLB_DNS:8802/collect"
echo ""

# 检查NLB健康状态
echo "检查NLB健康状态..."
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn $(aws elbv2 describe-load-balancers --names "$NLB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION") \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "$REGION" 2>/dev/null)

if [[ -n "$TARGET_GROUP_ARN" && "$TARGET_GROUP_ARN" != "None" ]]; then
    HEALTHY_TARGETS=$(aws elbv2 describe-target-health \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' \
      --output json \
      --region "$REGION" | jq length 2>/dev/null || echo "0")
    
    echo "健康目标数量: $HEALTHY_TARGETS"
    
    if [[ "$HEALTHY_TARGETS" == "0" ]]; then
        echo "警告: 没有健康的目标，测试可能会失败"
        read -p "是否继续测试? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "测试已取消"
            exit 0
        fi
    fi
else
    echo "警告: 无法检查目标组健康状态"
fi

echo ""
echo "开始发送测试数据..."
echo "=========================================="

# 发送测试消息
SUCCESS_COUNT=0
FAILED_COUNT=0

for i in $(seq 1 $MESSAGE_COUNT); do
    # 生成测试数据
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    USER_ID="test_user_$(printf "%04d" $i)"
    SESSION_ID="session_$(date +%s)_$i"
    
    TEST_DATA=$(cat << EOF
{
    "event": "page_view",
    "user_id": "$USER_ID",
    "session_id": "$SESSION_ID",
    "timestamp": "$TIMESTAMP",
    "page_url": "https://example.com/page$i",
    "user_agent": "TestAgent/1.0",
    "ip_address": "192.168.1.$((i % 255 + 1))",
    "referrer": "https://example.com/",
    "properties": {
        "page_title": "Test Page $i",
        "category": "test",
        "test_run": true,
        "message_number": $i,
        "project": "$PROJECT"
    }
}
EOF
)

    # Base64编码数据
    ENCODED_DATA=$(echo -n "$TEST_DATA" | base64 -w 0)

    # 发送HTTP请求
    echo -n "发送消息 $i/$MESSAGE_COUNT... "
    
    # 创建临时文件存储响应内容
    RESPONSE_FILE=$(mktemp)
    
    HTTP_STATUS=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" \
        -X POST "http://$NLB_DNS:8802/data/v1" \
        -H "Content-Type: application/json" \
        -H "User-Agent: ClickstreamTest/1.0" \
        -H "project: $PROJECT" \
        -d "$ENCODED_DATA" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null || echo "000")
    
    # 读取响应内容
    RESPONSE_BODY=$(cat "$RESPONSE_FILE" 2>/dev/null || echo "")
    
    if [[ "$HTTP_STATUS" == "200" ]]; then
        echo "✓ 成功 (HTTP $HTTP_STATUS)"
        if [[ -n "$RESPONSE_BODY" ]]; then
            echo "    响应: $RESPONSE_BODY"
        fi
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "✗ 失败 (HTTP $HTTP_STATUS)"
        if [[ -n "$RESPONSE_BODY" ]]; then
            echo "    错误响应: $RESPONSE_BODY"
        fi
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    # 清理临时文件
    rm -f "$RESPONSE_FILE"
    
    # 等待间隔
    if [[ $i -lt $MESSAGE_COUNT ]]; then
        sleep "$INTERVAL"
    fi
done

echo "=========================================="
echo "测试完成!"
echo "=========================================="
echo "总消息数: $MESSAGE_COUNT"
echo "成功发送: $SUCCESS_COUNT"
echo "发送失败: $FAILED_COUNT"
echo "成功率: $(( SUCCESS_COUNT * 100 / MESSAGE_COUNT ))%"
echo "项目名称: $PROJECT"
echo "数据编码: Base64"

if [[ $SUCCESS_COUNT -gt 0 ]]; then
    echo ""
    echo "✓ 数据已成功发送到点击流数据湖"
    echo ""
    echo "发送的数据特征:"
    echo "  - 数据格式: JSON (Base64编码)"
    echo "  - Project Header: $PROJECT"
    echo "  - MSK Topic: $PROJECT"
    echo ""
    echo "接下来您可以："
    echo "1. 检查Kafka主题 '$PROJECT' 中的消息"
    echo "2. 验证S3中的数据文件"
    echo "3. 查询Iceberg表中的数据"
    echo ""
    echo "验证命令示例:"
    echo "# 检查S3中的数据"
    echo "aws s3 ls s3://your-bucket/topics/$PROJECT/ --recursive"
    echo ""
    echo "# 检查MSK连接器状态"
    echo "aws kafkaconnect list-connectors --region $REGION"
else
    echo ""
    echo "✗ 所有消息发送失败"
    echo ""
    echo "请检查:"
    echo "1. NLB和ECS服务是否正常运行"
    echo "2. 安全组是否允许8802端口访问"
    echo "3. ECS任务是否健康"
    echo "4. CloudWatch日志中的错误信息"
fi

echo ""
echo "查看日志命令:"
echo "aws logs tail /ecs/clickstream-cluster --follow --region $REGION"

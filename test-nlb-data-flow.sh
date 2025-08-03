#!/bin/bash

# Clickstream Lakehouse 数据流测试脚本 (NLB 方案)
# 用于验证部署后的数据链路是否正常工作

# 默认配置
DEFAULT_REGION="us-east-1"
DEFAULT_NLB_NAME="clickstream-optimize-nlb"
DEFAULT_PROJECT="app_logs"

# 显示帮助信息
show_help() {
    cat << EOF
Clickstream Lakehouse 数据流测试脚本 (NLB 方案)

用法: $0 [选项]

选项:
    -r, --region REGION          AWS区域 (默认: $DEFAULT_REGION)
    -n, --nlb-name NAME          NLB名称 (默认: $DEFAULT_NLB_NAME)
    -p, --project PROJECT        项目名称/MSK主题名称 (默认: $DEFAULT_PROJECT)
    -c, --count COUNT            发送测试消息数量 (默认: 10)
    -i, --interval SECONDS       消息发送间隔 (默认: 1秒)
    -v, --verbose                显示详细的响应信息
    -h, --help                   显示此帮助信息

示例:
    $0                                    # 使用默认参数发送10条测试消息
    $0 -c 50 -i 0.5                     # 发送50条消息，间隔0.5秒
    $0 -r us-west-2 -n my-nlb           # 指定区域和NLB名称
    $0 -p my_topic -c 20                # 指定项目名称和消息数量
    $0 -v                                # 显示详细响应信息

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
VERBOSE=false

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
        -v|--verbose)
            VERBOSE=true
            shift
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
if [[ ! "$MESSAGE_COUNT" =~ ^[0-9]+$ ]] || [[ "$MESSAGE_COUNT" -le 0 ]]; then
    echo "错误: 消息数量必须是正整数"
    exit 1
fi

if [[ ! "$INTERVAL" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$INTERVAL <= 0" | bc -l) )); then
    echo "错误: 发送间隔必须是正数"
    exit 1
fi

# 获取NLB的DNS名称
echo "获取NLB DNS名称..."
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --names "$NLB_NAME" \
    --query 'LoadBalancers[0].DNSName' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

if [[ -z "$NLB_DNS" || "$NLB_DNS" == "None" ]]; then
    echo "错误: 无法找到NLB '$NLB_NAME' 在区域 '$REGION'"
    echo "请检查NLB名称和区域是否正确"
    exit 1
fi

echo "找到NLB DNS: $NLB_DNS"

# 构建测试端点URL
TEST_ENDPOINT="http://$NLB_DNS:8802/data/v1"

# 显示测试配置
echo "=========================================="
echo "Clickstream Lakehouse 数据流测试 (NLB)"
echo "=========================================="
echo "AWS区域: $REGION"
echo "NLB名称: $NLB_NAME"
echo "项目名称: $PROJECT"
echo "消息数量: $MESSAGE_COUNT"
echo "发送间隔: ${INTERVAL}秒"
echo "数据编码: Base64"
echo "详细模式: $VERBOSE"
echo "=========================================="
echo "NLB DNS: $NLB_DNS"
echo "测试端点: $TEST_ENDPOINT"
echo ""

# 统计变量
SUCCESS_COUNT=0
FAILED_COUNT=0

# 发送测试消息
for ((i=1; i<=MESSAGE_COUNT; i++)); do
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
    "referrer": "https://example.com/home",
    "user_agent": "Mozilla/5.0 (compatible; ClickstreamTest/1.0)",
    "ip_address": "192.168.1.$((i % 255 + 1))",
    "properties": {
        "page_title": "Test Page $i",
        "category": "test",
        "test_batch": "nlb_test_$(date +%s)"
    }
}
EOF
    )
    
    # Base64编码
    ENCODED_DATA=$(echo -n "$TEST_DATA" | base64 -w 0)
    
    # 发送请求
    echo -n "发送消息 $i/$MESSAGE_COUNT... "
    
    # 创建临时文件存储响应
    RESPONSE_FILE=$(mktemp)
    
    HTTP_STATUS=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" \
        -X POST "$TEST_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "project: $PROJECT" \
        -d "$ENCODED_DATA" \
        --connect-timeout 10 \
        --max-time 30 || echo "000")
    
    # 读取响应内容
    RESPONSE_BODY=$(cat "$RESPONSE_FILE")
    
    if [[ "$HTTP_STATUS" == "200" ]]; then
        echo "✓ 成功 (HTTP $HTTP_STATUS)"
        ((SUCCESS_COUNT++))
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo "    响应内容: $RESPONSE_BODY"
        fi
    else
        echo "✗ 失败 (HTTP $HTTP_STATUS)"
        ((FAILED_COUNT++))
        
        # 对于失败的请求，总是显示响应内容以便调试
        if [[ -n "$RESPONSE_BODY" ]]; then
            echo "    错误响应: $RESPONSE_BODY"
        fi
    fi
    
    # 清理临时文件
    rm -f "$RESPONSE_FILE"
    
    # 等待间隔（除了最后一条消息）
    if [[ $i -lt $MESSAGE_COUNT ]]; then
        sleep "$INTERVAL"
    fi
done

# 显示测试结果
echo ""
echo "=========================================="
echo "测试完成! (NLB)"
echo "=========================================="
echo "总消息数: $MESSAGE_COUNT"
echo "成功发送: $SUCCESS_COUNT"
echo "发送失败: $FAILED_COUNT"
echo "成功率: $(( SUCCESS_COUNT * 100 / MESSAGE_COUNT ))%"
echo "项目名称: $PROJECT"
echo "数据编码: Base64"
echo "NLB端点: $TEST_ENDPOINT"
echo ""

if [[ $FAILED_COUNT -gt 0 ]]; then
    echo "注意: 有 $FAILED_COUNT 条消息发送失败"
    echo "请检查:"
    echo "  - NLB健康检查状态"
    echo "  - ECS任务运行状态"
    echo "  - 安全组配置"
    echo "  - 网络连接"
    exit 1
else
    echo "所有消息发送成功! 数据应该已经进入MSK主题: $PROJECT"
    echo ""
    echo "后续验证步骤:"
    echo "  1. 检查MSK主题中的消息"
    echo "  2. 验证S3中的数据文件"
    echo "  3. 查询Iceberg表数据"
fi

echo ""
echo "提示: 使用 -v 或 --verbose 参数可以查看所有响应的详细内容"

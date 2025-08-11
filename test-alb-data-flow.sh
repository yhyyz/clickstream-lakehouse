#!/bin/bash
# 默认配置变量
DEFAULT_REGION="us-east-1"
DEFAULT_ALB_NAME="clickstream-alb-opti-alb"
DEFAULT_PROJECT="app_logs"
DEFAULT_COUNT=10
DEFAULT_INTERVAL=1

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

测试ALB+Nginx+Vector点击流数据链路

选项:
    -r, --region REGION          AWS区域 (默认: $DEFAULT_REGION)
    -a, --alb-name NAME          ALB名称 (默认: $DEFAULT_ALB_NAME)
    -p, --project PROJECT        项目名称/MSK主题名称 (默认: $DEFAULT_PROJECT)
    -c, --count COUNT            发送测试消息数量 (默认: $DEFAULT_COUNT)
    -i, --interval INTERVAL      消息发送间隔(秒) (默认: $DEFAULT_INTERVAL)
    -b, --batch_send             客户端batch发送 (默认: false)   
    -v, --verbose                显示详细的响应信息
    -h, --help                   显示此帮助信息

示例:
    $0                                                    # 使用默认参数
    $0 -r us-west-2 -a my-alb                           # 指定区域和ALB
    $0 -p my_topic -c 50 -i 0.5                         # 指定项目和发送参数
    $0 -v                                                # 显示详细响应信息

EOF
}

# 解析命令行参数
REGION="$DEFAULT_REGION"
ALB_NAME="$DEFAULT_ALB_NAME"
PROJECT="$DEFAULT_PROJECT"
COUNT="$DEFAULT_COUNT"
INTERVAL="$DEFAULT_INTERVAL"
VERBOSE=false
BATCH_SEND=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -a|--alb-name)
            ALB_NAME="$2"
            shift 2
            ;;
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        -c|--count)
            COUNT="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -b|--batch_send)
            BATCH_SEND=true
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

echo "=========================================="
echo "ALB+Nginx+Vector 点击流数据链路测试"
echo "=========================================="
echo "AWS区域: $REGION"
echo "ALB名称: $ALB_NAME"
echo "项目名称: $PROJECT"
echo "消息数量: $COUNT"
echo "发送间隔: ${INTERVAL}秒"
echo "详细模式: $VERBOSE"
echo "=========================================="

# 获取ALB DNS名称
echo "获取ALB DNS名称..."
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' \
    --output text \
    --region "$REGION")

if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
    echo "错误: 无法获取ALB DNS名称，请检查ALB名称是否正确"
    exit 1
fi

echo "ALB DNS: $ALB_DNS"
echo "测试端点: http://$ALB_DNS:8802/data/v1"
echo ""

# 发送测试数据
SUCCESS_COUNT=0
FAILED_COUNT=0

for ((i=1; i<=COUNT; i++)); do
    # 生成测试数据
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

    TEST_DATA_LIST=$(cat << EOF
[
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
},
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
]
EOF
    )

    # gzip + Base64编码
    if [[ "$BATCH_SEND" == "true" ]]; then
        ENCODED_DATA=$(echo -n "$TEST_DATA" |gzip| base64 -w 0)
    else
        ENCODED_DATA=$(echo -n "$TEST_DATA_LIST" |gzip| base64 -w 0) 
    fi
    # 发送请求
    echo -n "发送消息 $i/$COUNT... "
    
    # 创建临时文件存储响应
    RESPONSE_FILE=$(mktemp)
    
    HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" \
        -X POST "http://$ALB_DNS:8802/data/v1" \
        -H "project: $PROJECT" \
        -H "compression: gzip" \
        -d "$ENCODED_DATA" \
        --connect-timeout 10 \
        --max-time 30)
    
    # 读取响应内容
    RESPONSE_BODY=$(cat "$RESPONSE_FILE")
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "✓ 成功 (HTTP $HTTP_CODE)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo "    响应内容: $RESPONSE_BODY"
        fi
    else
        echo "✗ 失败 (HTTP $HTTP_CODE)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        
        # 对于失败的请求，总是显示响应内容以便调试
        if [[ -n "$RESPONSE_BODY" ]]; then
            echo "    错误响应: $RESPONSE_BODY"
        fi
    fi
    
    # 清理临时文件
    rm -f "$RESPONSE_FILE"
    
    # 等待间隔
    if [[ $i -lt $COUNT ]]; then
        sleep "$INTERVAL"
    fi
done

echo ""
echo "=========================================="
echo "测试完成!"
echo "=========================================="
echo "总消息数: $COUNT"
echo "成功发送: $SUCCESS_COUNT"
echo "发送失败: $FAILED_COUNT"
echo "成功率: $(( SUCCESS_COUNT * 100 / COUNT ))%"
echo "项目名称: $PROJECT"
echo ""

if [[ $SUCCESS_COUNT -gt 0 ]]; then
    echo "✓ 数据已发送到Vector，将通过Kafka发送到MSK主题: $PROJECT"
    echo "✓ 请检查MSK和下游数据处理组件以验证完整的数据链路"
else
    echo "✗ 所有请求都失败了，请检查："
    echo "  - ALB是否正常运行"
    echo "  - ECS服务是否健康"
    echo "  - 网络连接是否正常"
    echo "  - 安全组配置是否正确"
fi

echo ""
echo "提示: 使用 -v 或 --verbose 参数可以查看所有响应的详细内容"

#!/bin/bash

set -e

# 默认值
DEFAULT_REGION="us-east-1"
DEFAULT_VPC_ID=""
DEFAULT_MSK_CLUSTER=""

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

配置ALB+Nginx+Vector方案的安全组规则

选项:
    -r, --region REGION          AWS区域 (默认: $DEFAULT_REGION)
    -v, --vpc VPC_ID            VPC ID (必需)
    -m, --msk-cluster CLUSTER    MSK集群名称 (必需)
    --alb-sg ALB_SG_ID          ALB安全组ID (可选，自动检测)
    --ecs-sg ECS_SG_ID          ECS安全组ID (可选，自动检测)
    --msk-sg MSK_SG_ID          MSK安全组ID (可选，自动检测)
    --dry-run                   只显示将要执行的操作，不实际执行
    -h, --help                  显示此帮助信息

示例:
    $0 --vpc vpc-12345678 --msk-cluster my-msk-cluster
    $0 -v vpc-12345678 -m my-msk-cluster --dry-run

注意:
    - 脚本会自动检测相关的安全组ID
    - 如果安全组规则已存在，会跳过创建
    - 使用--dry-run可以预览将要执行的操作

EOF
}

# 解析命令行参数
REGION="$DEFAULT_REGION"
VPC_ID=""
MSK_CLUSTER=""
ALB_SG_ID=""
ECS_SG_ID=""
MSK_SG_ID=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -v|--vpc)
            VPC_ID="$2"
            shift 2
            ;;
        -m|--msk-cluster)
            MSK_CLUSTER="$2"
            shift 2
            ;;
        --alb-sg)
            ALB_SG_ID="$2"
            shift 2
            ;;
        --ecs-sg)
            ECS_SG_ID="$2"
            shift 2
            ;;
        --msk-sg)
            MSK_SG_ID="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "错误: 未知参数 $1"
            show_help
            exit 1
            ;;
    esac
done

# 验证必需参数
if [[ -z "$VPC_ID" ]]; then
    echo "错误: 必须指定VPC ID (--vpc)"
    exit 1
fi

if [[ -z "$MSK_CLUSTER" ]]; then
    echo "错误: 必须指定MSK集群名称 (--msk-cluster)"
    exit 1
fi

echo "=== ALB+Nginx+Vector 安全组配置脚本 ==="
echo "区域: $REGION"
echo "VPC: $VPC_ID"
echo "MSK集群: $MSK_CLUSTER"
echo "Dry Run: $DRY_RUN"
echo ""

# 函数：检查安全组规则是否存在
check_sg_rule_exists() {
    local sg_id="$1"
    local protocol="$2"
    local port="$3"
    local source="$4"
    local rule_type="$5"  # ingress 或 egress
    
    if [[ "$rule_type" == "ingress" ]]; then
        if [[ "$source" =~ ^sg- ]]; then
            # 源是安全组
            aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --region "$REGION" \
                --query "SecurityGroups[0].IpPermissions[?IpProtocol=='$protocol' && FromPort==\`$port\` && ToPort==\`$port\` && UserIdGroupPairs[?GroupId=='$source']]" \
                --output text | grep -q "$port" 2>/dev/null
        else
            # 源是CIDR
            aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --region "$REGION" \
                --query "SecurityGroups[0].IpPermissions[?IpProtocol=='$protocol' && FromPort==\`$port\` && ToPort==\`$port\` && IpRanges[?CidrIp=='$source']]" \
                --output text | grep -q "$port" 2>/dev/null
        fi
    else
        # egress规则检查类似，但这里主要关注ingress
        return 1
    fi
}

# 函数：添加安全组规则
add_sg_rule() {
    local sg_id="$1"
    local protocol="$2"
    local port="$3"
    local source="$4"
    local description="$5"
    
    echo "  添加规则: $sg_id <- $protocol:$port from $source"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY RUN] 跳过实际执行"
        return
    fi
    
    if check_sg_rule_exists "$sg_id" "$protocol" "$port" "$source" "ingress"; then
        echo "    规则已存在，跳过"
        return
    fi
    
    if [[ "$source" =~ ^sg- ]]; then
        # 源是安全组
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol "$protocol" \
            --port "$port" \
            --source-group "$source" \
            --region "$REGION" >/dev/null 2>&1 && echo "    ✓ 成功添加" || echo "    ✗ 添加失败或已存在"
    else
        # 源是CIDR
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol "$protocol" \
            --port "$port" \
            --cidr "$source" \
            --region "$REGION" >/dev/null 2>&1 && echo "    ✓ 成功添加" || echo "    ✗ 添加失败或已存在"
    fi
}

# 函数：自动检测ALB安全组
detect_alb_security_group() {
    if [[ -n "$ALB_SG_ID" ]]; then
        echo "使用指定的ALB安全组: $ALB_SG_ID"
        return
    fi
    
    echo "自动检测ALB安全组..."
    ALB_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=clickstream-alb-opti-alb-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$ALB_SG_ID" == "None" || -z "$ALB_SG_ID" ]]; then
        echo "警告: 未找到ALB安全组，请先部署ALB或手动指定安全组ID"
        ALB_SG_ID=""
    else
        echo "检测到ALB安全组: $ALB_SG_ID"
    fi
}

# 函数：自动检测ECS安全组
detect_ecs_security_group() {
    if [[ -n "$ECS_SG_ID" ]]; then
        echo "使用指定的ECS安全组: $ECS_SG_ID"
        return
    fi
    
    echo "自动检测ECS安全组..."
    ECS_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=clickstream-alb-ecs-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$ECS_SG_ID" == "None" || -z "$ECS_SG_ID" ]]; then
        echo "警告: 未找到ECS安全组，请先部署ECS服务或手动指定安全组ID"
        ECS_SG_ID=""
    else
        echo "检测到ECS安全组: $ECS_SG_ID"
    fi
}

# 函数：自动检测MSK安全组
detect_msk_security_group() {
    if [[ -n "$MSK_SG_ID" ]]; then
        echo "使用指定的MSK安全组: $MSK_SG_ID"
        return
    fi
    
    echo "自动检测MSK安全组..."
    
    # 获取MSK集群信息
    local cluster_arn
    cluster_arn=$(aws kafka list-clusters \
        --region "$REGION" \
        --query "ClusterInfoList[?ClusterName=='$MSK_CLUSTER'].ClusterArn" \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$cluster_arn" ]]; then
        echo "错误: 未找到MSK集群 $MSK_CLUSTER"
        return
    fi
    
    # 获取MSK集群的安全组
    MSK_SG_ID=$(aws kafka describe-cluster \
        --cluster-arn "$cluster_arn" \
        --region "$REGION" \
        --query 'ClusterInfo.BrokerNodeGroupInfo.SecurityGroups[0]' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$MSK_SG_ID" == "None" || -z "$MSK_SG_ID" ]]; then
        echo "警告: 未找到MSK安全组"
        MSK_SG_ID=""
    else
        echo "检测到MSK安全组: $MSK_SG_ID"
    fi
}

# 主要配置函数
configure_security_groups() {
    echo "开始配置安全组规则..."
    echo ""
    
    # 1. 配置ALB安全组 - 允许外网访问8802端口
    if [[ -n "$ALB_SG_ID" ]]; then
        echo "1. 配置ALB安全组 ($ALB_SG_ID):"
        add_sg_rule "$ALB_SG_ID" "tcp" "8802" "0.0.0.0/0" "Allow HTTP traffic from internet"
        echo ""
    else
        echo "1. 跳过ALB安全组配置 (未找到ALB安全组)"
        echo ""
    fi
    
    # 2. 配置ECS安全组 - 允许ALB安全组的所有流量访问
    if [[ -n "$ECS_SG_ID" && -n "$ALB_SG_ID" ]]; then
        echo "2. 配置ECS安全组 ($ECS_SG_ID):"
        add_sg_rule "$ECS_SG_ID" "tcp" "8802" "$ALB_SG_ID" "Allow traffic from ALB to Nginx"
        add_sg_rule "$ECS_SG_ID" "tcp" "8685" "$ALB_SG_ID" "Allow traffic from ALB to Vector HTTP"
        add_sg_rule "$ECS_SG_ID" "tcp" "8686" "$ALB_SG_ID" "Allow traffic from ALB to Vector health check"
        # 允许ECS安全组内部通信
        add_sg_rule "$ECS_SG_ID" "tcp" "8685" "$ECS_SG_ID" "Allow internal communication to Vector"
        add_sg_rule "$ECS_SG_ID" "tcp" "8686" "$ECS_SG_ID" "Allow internal health check"
        echo ""
    else
        echo "2. 跳过ECS安全组配置 (缺少ALB或ECS安全组)"
        echo ""
    fi
    
    # 3. 配置MSK安全组 - 允许ECS安全组的所有流量访问
    if [[ -n "$MSK_SG_ID" && -n "$ECS_SG_ID" ]]; then
        echo "3. 配置MSK安全组 ($MSK_SG_ID):"
        add_sg_rule "$MSK_SG_ID" "tcp" "9092" "$ECS_SG_ID" "Allow Kafka traffic from ECS"
        add_sg_rule "$MSK_SG_ID" "tcp" "9094" "$ECS_SG_ID" "Allow Kafka TLS traffic from ECS"
        add_sg_rule "$MSK_SG_ID" "tcp" "9096" "$ECS_SG_ID" "Allow Kafka SASL traffic from ECS"
        add_sg_rule "$MSK_SG_ID" "tcp" "2181" "$ECS_SG_ID" "Allow Zookeeper traffic from ECS"
        echo ""
    else
        echo "3. 跳过MSK安全组配置 (缺少MSK或ECS安全组)"
        echo ""
    fi
}

# 主函数
main() {
    # 检测安全组
    detect_alb_security_group
    detect_ecs_security_group
    detect_msk_security_group
    
    echo ""
    echo "检测到的安全组:"
    echo "  ALB安全组: ${ALB_SG_ID:-未找到}"
    echo "  ECS安全组: ${ECS_SG_ID:-未找到}"
    echo "  MSK安全组: ${MSK_SG_ID:-未找到}"
    echo ""
    
    # 配置安全组规则
    configure_security_groups
    
    echo "=== 安全组配置完成 ==="
    
    # 保存配置信息
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > tmp/security-groups-info.json << EOF
{
  "configuration_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$REGION",
  "vpc_id": "$VPC_ID",
  "msk_cluster": "$MSK_CLUSTER",
  "security_groups": {
    "alb_security_group_id": "${ALB_SG_ID:-null}",
    "ecs_security_group_id": "${ECS_SG_ID:-null}",
    "msk_security_group_id": "${MSK_SG_ID:-null}"
  },
  "configured_rules": {
    "alb_rules": [
      "tcp:8802 from 0.0.0.0/0",
    ],
    "ecs_rules": [
      "tcp:8802 from ALB SG",
      "tcp:8685 from ALB SG",
      "tcp:8686 from ALB SG",
      "tcp:8685 from ECS SG",
      "tcp:8686 from ECS SG"
    ],
    "msk_rules": [
      "tcp:9092 from ECS SG",
      "tcp:9094 from ECS SG",
      "tcp:9096 from ECS SG",
      "tcp:2181 from ECS SG"
    ]
  }
}
EOF
        echo "配置信息已保存到 tmp/security-groups-info.json"
    fi
}

# 执行主函数
main

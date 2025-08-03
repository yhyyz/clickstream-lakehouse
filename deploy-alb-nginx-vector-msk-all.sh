#!/bin/bash

# Clickstream Lakehouse 统一部署脚本 (ALB + Nginx + Vector 方案)
# 数据链路: ALB -> ECS -> MSK -> MSK Connector -> Iceberg

set -e

# 默认值
DEFAULT_REGION="us-east-1"
DEFAULT_S3_BUCKET=""
DEFAULT_VPC_ID=""
DEFAULT_MSK_CLUSTER_NAME=""
DEFAULT_GLUE_DATABASE="iceberg_db"
DEFAULT_DESIRED_COUNT=4
DEFAULT_WORKER_COUNT=6

# 部署阶段标志
DEPLOY_DOCKER=true
DEPLOY_ECS=true
DEPLOY_ALB=true
DEPLOY_MSK_TOPICS=true
DEPLOY_ICEBERG_CONNECTOR=true
DEPLOY_S3_CONNECTOR=true

# 显示帮助信息
show_help() {
    cat << EOF
Clickstream Lakehouse 统一部署脚本 (ALB + Nginx + Vector 方案)

用法: $0 [选项]

必需参数:
    -b, --s3-bucket BUCKET           S3存储桶名称 (用于数据存储和插件)
    -m, --msk-cluster CLUSTER        MSK集群名称

可选参数:
    -r, --region REGION              AWS区域 (默认: $DEFAULT_REGION)
    -v, --vpc VPC_ID                 VPC ID (如果不指定，将从MSK集群自动获取)
    -d, --glue-database DATABASE     Glue数据库名称 (默认: $DEFAULT_GLUE_DATABASE)
    -c, --desired-count COUNT        ECS任务数量 (默认: $DEFAULT_DESIRED_COUNT)
    -w, --worker-count COUNT         MSK连接器Worker数量 (默认: $DEFAULT_WORKER_COUNT)

部署阶段控制:
    --skip-docker                    跳过Docker镜像构建
    --skip-ecs                       跳过ECS部署
    --skip-alb                       跳过ALB部署
    --skip-msk-topics               跳过MSK主题创建
    --skip-iceberg-connector        跳过Iceberg连接器创建
    --skip-s3-connector             跳过S3连接器创建

其他选项:
    -h, --help                       显示此帮助信息
    --dry-run                        显示将要执行的命令但不实际执行

示例:
    # 完整部署
    $0 -b my-clickstream-bucket -m my-msk-cluster

    # 跳过Docker构建的部署
    $0 -b my-bucket -m my-cluster --skip-docker

    # 只部署MSK相关组件
    $0 -b my-bucket -m my-cluster --skip-docker --skip-ecs --skip-alb

    # 指定VPC（如果自动检测失败）
    $0 -b my-bucket -v vpc-12345678 -m my-cluster

数据链路:
    ALB -> ECS (nginx+vector) -> MSK -> MSK Connector -> Iceberg/S3

EOF
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -b|--s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            -v|--vpc)
                VPC_ID="$2"
                shift 2
                ;;
            -m|--msk-cluster)
                MSK_CLUSTER_NAME="$2"
                shift 2
                ;;
            -d|--glue-database)
                GLUE_DATABASE="$2"
                shift 2
                ;;
            -c|--desired-count)
                DESIRED_COUNT="$2"
                shift 2
                ;;
            -w|--worker-count)
                WORKER_COUNT="$2"
                shift 2
                ;;
            --skip-docker)
                DEPLOY_DOCKER=false
                shift
                ;;
            --skip-ecs)
                DEPLOY_ECS=false
                shift
                ;;
            --skip-alb)
                DEPLOY_ALB=false
                shift
                ;;
            --skip-msk-topics)
                DEPLOY_MSK_TOPICS=false
                shift
                ;;
            --skip-iceberg-connector)
                DEPLOY_ICEBERG_CONNECTOR=false
                shift
                ;;
            --skip-s3-connector)
                DEPLOY_S3_CONNECTOR=false
                shift
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
                echo "使用 $0 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
}

# 验证必需参数
validate_parameters() {
    local errors=()
    
    if [[ -z "$S3_BUCKET" ]]; then
        errors+=("S3存储桶名称是必需的 (--s3-bucket)")
    fi
    
    if [[ -z "$MSK_CLUSTER_NAME" ]]; then
        errors+=("MSK集群名称是必需的 (--msk-cluster)")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "错误: 缺少必需参数:"
        for error in "${errors[@]}"; do
            echo "  - $error"
        done
        echo ""
        show_help
        exit 1
    fi
}

# 执行命令（支持dry-run模式）
execute_command() {
    local cmd="$1"
    local description="$2"
    
    echo "=========================================="
    echo "执行: $description"
    echo "命令: $cmd"
    echo "=========================================="
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] 将执行上述命令"
        return 0
    fi
    
    eval "$cmd"
    if [[ $? -ne 0 ]]; then
        echo "错误: $description 失败"
        exit 1
    fi
    echo "$description 完成"
    echo ""
}

# 获取MSK集群的VPC信息
get_msk_vpc_info() {
    echo "获取MSK集群VPC信息..."
    
    # 首先获取集群ARN
    CLUSTER_ARN=$(aws kafka list-clusters --cluster-name-filter "$MSK_CLUSTER_NAME" --query 'ClusterInfoList[0].ClusterArn' --output text --region "$REGION" 2>/dev/null || echo "")
    
    if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
        echo "错误: 无法找到MSK集群 '$MSK_CLUSTER_NAME'"
        exit 1
    fi
    
    echo "找到MSK集群ARN: $CLUSTER_ARN"
    
    # 如果用户没有指定VPC，从MSK集群获取
    if [[ -z "$VPC_ID" ]]; then
        echo "从MSK集群获取VPC信息..."
        VPC_ID=$(aws kafka describe-cluster --cluster-arn "$CLUSTER_ARN" --query 'ClusterInfo.BrokerNodeGroupInfo.ClientSubnets[0]' --output text --region "$REGION" 2>/dev/null)
        
        if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
            # 从子网ID获取VPC ID
            VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$VPC_ID" --query 'Subnets[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
        fi
        
        if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
            echo "错误: 无法从MSK集群获取VPC信息"
            echo "请手动指定VPC ID: --vpc vpc-xxxxxxxxx"
            exit 1
        fi
        
        echo "从MSK集群获取到VPC ID: $VPC_ID"
    else
        echo "使用用户指定的VPC ID: $VPC_ID"
    fi
}

# 获取MSK集群的bootstrap servers
get_msk_bootstrap_servers() {
    echo "获取MSK集群bootstrap servers..."
    
    # 使用之前获取的CLUSTER_ARN
    if [[ -z "$CLUSTER_ARN" ]]; then
        CLUSTER_ARN=$(aws kafka list-clusters --cluster-name-filter "$MSK_CLUSTER_NAME" --query 'ClusterInfoList[0].ClusterArn' --output text --region "$REGION" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
        echo "错误: 无法找到MSK集群 '$MSK_CLUSTER_NAME'"
        exit 1
    fi
    
    # 获取bootstrap servers
    KAFKA_BOOTSTRAP_SERVERS=$(aws kafka get-bootstrap-brokers --cluster-arn "$CLUSTER_ARN" --query 'BootstrapBrokerString' --output text --region "$REGION" 2>/dev/null || echo "")
    
    if [[ -z "$KAFKA_BOOTSTRAP_SERVERS" || "$KAFKA_BOOTSTRAP_SERVERS" == "None" ]]; then
        echo "警告: 无法自动获取MSK bootstrap servers，将使用集群名称"
        KAFKA_BOOTSTRAP_SERVERS="$MSK_CLUSTER_NAME"
    else
        echo "MSK Bootstrap Servers: $KAFKA_BOOTSTRAP_SERVERS"
        # 提取第一个broker的主机名用于ECS部署
        KAFKA_BROKER_HOST=$(echo "$KAFKA_BOOTSTRAP_SERVERS" | cut -d',' -f1 | cut -d':' -f1)
        echo "Kafka Broker Host: $KAFKA_BROKER_HOST"
    fi
}

# 主部署函数
main() {
    # 设置默认值
    REGION="${REGION:-$DEFAULT_REGION}"
    GLUE_DATABASE="${GLUE_DATABASE:-$DEFAULT_GLUE_DATABASE}"
    DESIRED_COUNT="${DESIRED_COUNT:-$DEFAULT_DESIRED_COUNT}"
    WORKER_COUNT="${WORKER_COUNT:-$DEFAULT_WORKER_COUNT}"
    DRY_RUN="${DRY_RUN:-false}"
    
    # 解析参数
    parse_arguments "$@"
    
    # 验证参数
    validate_parameters
    
    # 显示配置信息
    echo "=========================================="
    echo "Clickstream Lakehouse 部署配置 (ALB + Nginx + Vector)"
    echo "=========================================="
    echo "AWS区域: $REGION"
    echo "S3存储桶: $S3_BUCKET"
    echo "MSK集群: $MSK_CLUSTER_NAME"
    echo "VPC ID: ${VPC_ID:-'将从MSK集群自动获取'}"
    echo "Glue数据库: $GLUE_DATABASE"
    echo "ECS任务数量: $DESIRED_COUNT"
    echo "MSK Worker数量: $WORKER_COUNT"
    echo "Dry Run模式: $DRY_RUN"
    echo ""
    echo "部署阶段:"
    echo "  Docker镜像构建: $DEPLOY_DOCKER"
    echo "  ECS部署: $DEPLOY_ECS"
    echo "  ALB部署: $DEPLOY_ALB"
    echo "  MSK主题创建: $DEPLOY_MSK_TOPICS"
    echo "  Iceberg连接器: $DEPLOY_ICEBERG_CONNECTOR"
    echo "  S3连接器: $DEPLOY_S3_CONNECTOR"
    echo "=========================================="
    
    if [[ "$DRY_RUN" != "true" ]]; then
        read -p "确认开始部署? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "部署已取消"
            exit 0
        fi
    fi
    
    # 获取MSK集群信息（包括VPC和bootstrap servers）
    get_msk_vpc_info
    get_msk_bootstrap_servers
    
    # 更新配置显示
    echo ""
    echo "=========================================="
    echo "最终部署配置"
    echo "=========================================="
    echo "VPC ID: $VPC_ID"
    echo "Kafka Bootstrap Servers: $KAFKA_BOOTSTRAP_SERVERS"
    echo "Kafka Broker Host: ${KAFKA_BROKER_HOST:-$MSK_CLUSTER_NAME}"
    echo "=========================================="
    
    # 阶段1: 构建Docker镜像
    if [[ "$DEPLOY_DOCKER" == "true" ]]; then
        execute_command \
            "cd src/ingestion/alb-nginx-vector/docker && ./build-all-images.sh --region $REGION" \
            "构建Docker镜像 (Nginx + Vector)"
    fi
    
    # 阶段2: 部署ECS服务
    if [[ "$DEPLOY_ECS" == "true" ]]; then
        # 确保有kafka broker host信息
        if [[ -z "$KAFKA_BROKER_HOST" ]]; then
            KAFKA_BROKER_HOST="$MSK_CLUSTER_NAME"
        fi
        
        execute_command \
            "cd src/ingestion/alb-nginx-vector/ecs && ./deploy-ecs-optimized.sh --region $REGION --vpc $VPC_ID --desired-count $DESIRED_COUNT --kafka-broker-host $KAFKA_BROKER_HOST" \
            "部署ECS服务 (ALB + Nginx + Vector)"
    fi
    
    # 阶段3: 部署ALB
    if [[ "$DEPLOY_ALB" == "true" ]]; then
        execute_command \
            "cd src/ingestion/alb-nginx-vector/alb && ./deploy-alb-optimized.sh --region $REGION --vpc $VPC_ID" \
            "部署应用负载均衡器 (ALB)"
    fi
    
    # 阶段4: 创建MSK主题
    if [[ "$DEPLOY_MSK_TOPICS" == "true" ]]; then
        execute_command \
            "cd src/msk-iceberg && ./create-msk-topics.sh --region $REGION --cluster-name $MSK_CLUSTER_NAME" \
            "创建MSK主题"
    fi
    
    # 阶段5: 创建Iceberg连接器
    if [[ "$DEPLOY_ICEBERG_CONNECTOR" == "true" ]]; then
        execute_command \
            "cd src/msk-iceberg && ./create-s3-iceberg-connector-optimized.sh $S3_BUCKET $MSK_CLUSTER_NAME" \
            "创建Iceberg连接器"
    fi
    
    # 阶段6: 创建S3连接器
    if [[ "$DEPLOY_S3_CONNECTOR" == "true" ]]; then
        execute_command \
            "cd src/msk-iceberg && ./create-s3-json-connector-optimized.sh $S3_BUCKET $MSK_CLUSTER_NAME" \
            "创建S3 JSON连接器"
    fi
    
    echo "=========================================="
    echo "部署完成!"
    echo "=========================================="
    echo "数据链路已建立: ALB -> ECS -> MSK -> Iceberg/S3"
    echo ""
    echo "生成的信息文件:"
    echo "  - src/ingestion/alb-nginx-vector/tmp/docker-images-info.json"
    echo "  - src/ingestion/alb-nginx-vector/tmp/ecs-service-info.json"
    echo "  - src/ingestion/alb-nginx-vector/tmp/alb-info.json"
    echo "  - src/msk-iceberg/msk-topics-info.json"
    echo "  - src/msk-iceberg/msk-iceberg-connector-info.json"
    echo "  - src/msk-iceberg/msk-s3-json-connector-info.json"
    echo ""
    echo "请检查各个组件的状态，确保部署成功。"
}

# 执行主函数
main "$@"

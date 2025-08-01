#!/bin/bash

set -e

# 默认值
DEFAULT_REGION="us-east-1"
DEFAULT_VPC_ID=""
DEFAULT_CLUSTER_NAME="clickstream-cluster"
DEFAULT_SERVICE_NAME="clickstream-optimized-service"
FORCE_RECREATE=false

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

创建网络负载均衡器(NLB)并与ECS服务绑定的脚本

选项:
    -r, --region REGION          AWS区域 (默认: $DEFAULT_REGION)
    -v, --vpc VPC_ID            VPC ID (如果不指定，将自动从ECS服务获取)
    -c, --cluster CLUSTER_NAME   ECS集群名称 (默认: $DEFAULT_CLUSTER_NAME)
    -s, --service SERVICE_NAME   ECS服务名称 (默认: $DEFAULT_SERVICE_NAME)
    -f, --force                 强制删除并重新创建资源
    -h, --help                  显示此帮助信息

示例:
    $0 --region us-west-2 --cluster my-cluster --service my-service
    $0 -r us-east-1 -c clickstream-cluster -s clickstream-service --force

注意:
    - 脚本会自动检测ECS服务所在的子网并启用跨AZ负载均衡
    - 如果资源已存在，默认跳过创建，除非使用 --force 参数
    - NLB和目标组名称将基于服务名称自动生成
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
            -v|--vpc)
                VPC_ID="$2"
                shift 2
                ;;
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_RECREATE=true
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

    # 设置默认值
    REGION=${REGION:-$DEFAULT_REGION}
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    SERVICE_NAME=${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}
    
    # 基于服务名称生成资源名称，确保不超过32字符限制
    # 使用服务名称的前20个字符 + 后缀
    SERVICE_PREFIX=$(echo "$SERVICE_NAME" | cut -c1-20)
    NLB_NAME="${SERVICE_PREFIX}-nlb"
    TARGET_GROUP_NAME="${SERVICE_PREFIX}-tg"
}

# 验证必要参数
validate_parameters() {
    if [[ -z "$REGION" ]]; then
        echo "错误: 必须指定区域"
        exit 1
    fi
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "错误: 必须指定集群名称"
        exit 1
    fi
    
    if [[ -z "$SERVICE_NAME" ]]; then
        echo "错误: 必须指定服务名称"
        exit 1
    fi
}

# 获取ECS服务信息
get_ecs_service_info() {
    echo "获取ECS服务信息..."
    
    # 检查ECS服务是否存在
    if ! aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].serviceName' \
        --output text 2>/dev/null | grep -q "$SERVICE_NAME"; then
        echo "错误: ECS服务 $SERVICE_NAME 在集群 $CLUSTER_NAME 中不存在"
        exit 1
    fi
    
    # 获取ECS服务所在的子网（用于确定可用区）
    echo "获取ECS服务所在的子网..."
    ECS_SUBNETS=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' \
        --output text | tr '\t' ' ')
    
    if [[ -z "$ECS_SUBNETS" ]]; then
        echo "错误: 无法获取ECS服务的子网信息"
        exit 1
    fi
    
    echo "ECS服务所在子网: $ECS_SUBNETS"
    
    # 如果没有指定VPC，从ECS服务获取
    if [[ -z "$VPC_ID" ]]; then
        echo "自动获取VPC ID..."
        VPC_ID=$(echo $ECS_SUBNETS | awk '{print $1}' | xargs -I {} aws ec2 describe-subnets \
            --subnet-ids {} \
            --region "$REGION" \
            --query 'Subnets[0].VpcId' \
            --output text)
        
        if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
            echo "错误: 无法获取VPC ID"
            exit 1
        fi
        echo "检测到VPC ID: $VPC_ID"
    fi
    
    # 获取ECS服务所在的可用区
    echo "获取ECS服务所在的可用区..."
    ECS_AZS=$(aws ec2 describe-subnets \
        --subnet-ids $ECS_SUBNETS \
        --region "$REGION" \
        --query 'Subnets[].AvailabilityZone' \
        --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')
    
    if [[ -z "$ECS_AZS" ]]; then
        echo "错误: 无法获取ECS服务的可用区信息"
        exit 1
    fi
    
    echo "ECS服务所在可用区: $ECS_AZS"
    
    # 获取VPC中的公有子网，并筛选出与ECS服务相同可用区的子网
    echo "获取VPC中与ECS服务相同可用区的公有子网..."
    
    # 首先获取VPC中的所有子网
    ALL_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --region "$REGION" \
        --query 'Subnets[].SubnetId' \
        --output text)
    
    if [[ -z "$ALL_SUBNETS" ]]; then
        echo "错误: 无法获取VPC中的子网"
        exit 1
    fi
    
    # 检查每个子网是否为公有子网，并且在ECS服务的可用区中
    PUBLIC_SUBNETS=""
    for subnet in $ALL_SUBNETS; do
        # 获取子网的可用区
        subnet_az=$(aws ec2 describe-subnets \
            --subnet-ids "$subnet" \
            --region "$REGION" \
            --query 'Subnets[0].AvailabilityZone' \
            --output text)
        
        # 检查是否在ECS服务的可用区中
        if echo "$ECS_AZS" | grep -q "$subnet_az"; then
            # 检查是否为公有子网（通过路由表判断）
            route_table_id=$(aws ec2 describe-route-tables \
                --filters "Name=association.subnet-id,Values=$subnet" \
                --region "$REGION" \
                --query 'RouteTables[0].RouteTableId' \
                --output text)
            
            # 如果没有显式关联的路由表，检查主路由表
            if [[ "$route_table_id" == "None" || -z "$route_table_id" ]]; then
                route_table_id=$(aws ec2 describe-route-tables \
                    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
                    --region "$REGION" \
                    --query 'RouteTables[0].RouteTableId' \
                    --output text)
            fi
            
            # 检查路由表是否有指向互联网网关的路由
            has_igw_route=$(aws ec2 describe-route-tables \
                --route-table-ids "$route_table_id" \
                --region "$REGION" \
                --query 'RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, `igw-`)]' \
                --output text)
            
            if [[ -n "$has_igw_route" ]]; then
                PUBLIC_SUBNETS="$PUBLIC_SUBNETS $subnet"
                echo "找到公有子网: $subnet (可用区: $subnet_az)"
            fi
        fi
    done
    
    # 清理前后空格
    SUBNETS=$(echo $PUBLIC_SUBNETS | xargs)
    
    if [[ -z "$SUBNETS" ]]; then
        echo "错误: 在ECS服务所在的可用区中未找到公有子网"
        echo "ECS服务可用区: $ECS_AZS"
        echo "请确保VPC中存在与ECS服务相同可用区的公有子网"
        exit 1
    fi
    
    echo "选择的NLB公有子网: $SUBNETS"
    
    # 获取容器端口
    CONTAINER_PORT=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].taskDefinition' \
        --output text | xargs -I {} aws ecs describe-task-definition \
        --task-definition {} \
        --region "$REGION" \
        --query 'taskDefinition.containerDefinitions[0].portMappings[0].containerPort' \
        --output text)
    
    if [[ -z "$CONTAINER_PORT" || "$CONTAINER_PORT" == "None" ]]; then
        CONTAINER_PORT=8802  # 默认端口
        echo "警告: 无法获取容器端口，使用默认端口 $CONTAINER_PORT"
    else
        echo "检测到容器端口: $CONTAINER_PORT"
    fi
    
    # 获取容器名称
    CONTAINER_NAME=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].taskDefinition' \
        --output text | xargs -I {} aws ecs describe-task-definition \
        --task-definition {} \
        --region "$REGION" \
        --query 'taskDefinition.containerDefinitions[0].name' \
        --output text)
    
    if [[ -z "$CONTAINER_NAME" || "$CONTAINER_NAME" == "None" ]]; then
        CONTAINER_NAME="clickstream-container"  # 默认容器名
        echo "警告: 无法获取容器名称，使用默认名称 $CONTAINER_NAME"
    else
        echo "检测到容器名称: $CONTAINER_NAME"
    fi
}

# 检查资源是否存在
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    
    case $resource_type in
        "target-group")
            aws elbv2 describe-target-groups \
                --names "$resource_name" \
                --region "$REGION" \
                --query 'TargetGroups[0].TargetGroupArn' \
                --output text 2>/dev/null | grep -v "None"
            ;;
        "load-balancer")
            aws elbv2 describe-load-balancers \
                --names "$resource_name" \
                --region "$REGION" \
                --query 'LoadBalancers[0].LoadBalancerArn' \
                --output text 2>/dev/null | grep -v "None"
            ;;
    esac
}

# 删除资源
delete_resource() {
    local resource_type=$1
    local resource_arn=$2
    
    case $resource_type in
        "target-group")
            echo "删除目标组: $resource_arn"
            aws elbv2 delete-target-group \
                --target-group-arn "$resource_arn" \
                --region "$REGION"
            ;;
        "load-balancer")
            echo "删除负载均衡器: $resource_arn"
            aws elbv2 delete-load-balancer \
                --load-balancer-arn "$resource_arn" \
                --region "$REGION"
            # 等待删除完成
            echo "等待负载均衡器删除完成..."
            aws elbv2 wait load-balancer-not-exists \
                --load-balancer-arns "$resource_arn" \
                --region "$REGION"
            ;;
    esac
}

# 创建目标组
create_target_group() {
    echo "创建目标组: $TARGET_GROUP_NAME"
    
    # 检查目标组是否存在
    EXISTING_TG_ARN=$(check_resource_exists "target-group" "$TARGET_GROUP_NAME")
    
    if [[ -n "$EXISTING_TG_ARN" ]]; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            delete_resource "target-group" "$EXISTING_TG_ARN"
        else
            echo "目标组已存在，跳过创建: $EXISTING_TG_ARN"
            TARGET_GROUP_ARN="$EXISTING_TG_ARN"
            return
        fi
    fi
    
    echo "正在创建目标组，参数如下:"
    echo "  名称: $TARGET_GROUP_NAME"
    echo "  端口: $CONTAINER_PORT"
    echo "  VPC: $VPC_ID"
    echo "  区域: $REGION"
    
    if ! TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
        --name "$TARGET_GROUP_NAME" \
        --protocol TCP \
        --port "$CONTAINER_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-protocol TCP \
        --health-check-port "$CONTAINER_PORT" \
        --health-check-interval-seconds 30 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 2 \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>&1); then
        echo "错误: 创建目标组失败"
        echo "错误信息: $TARGET_GROUP_ARN"
        exit 1
    fi
    
    if [[ -z "$TARGET_GROUP_ARN" || "$TARGET_GROUP_ARN" == "None" ]]; then
        echo "错误: 目标组创建失败，未返回ARN"
        exit 1
    fi
    
    echo "目标组已创建: $TARGET_GROUP_ARN"
}

# 创建网络负载均衡器
create_load_balancer() {
    echo "创建网络负载均衡器: $NLB_NAME"
    
    # 检查NLB是否存在
    EXISTING_NLB_ARN=$(check_resource_exists "load-balancer" "$NLB_NAME")
    
    if [[ -n "$EXISTING_NLB_ARN" ]]; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            delete_resource "load-balancer" "$EXISTING_NLB_ARN"
        else
            echo "负载均衡器已存在，跳过创建: $EXISTING_NLB_ARN"
            NLB_ARN="$EXISTING_NLB_ARN"
            return
        fi
    fi
    
    echo "正在创建网络负载均衡器，参数如下:"
    echo "  名称: $NLB_NAME"
    echo "  子网: $SUBNETS"
    echo "  区域: $REGION"
    
    if ! NLB_ARN=$(aws elbv2 create-load-balancer \
        --name "$NLB_NAME" \
        --scheme internet-facing \
        --type network \
        --subnets $SUBNETS \
        --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>&1); then
        echo "错误: 创建负载均衡器失败"
        echo "错误信息: $NLB_ARN"
        exit 1
    fi
    
    if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
        echo "错误: 负载均衡器创建失败，未返回ARN"
        exit 1
    fi
    
    echo "NLB已创建: $NLB_ARN"
    
    # 启用跨AZ负载均衡
    echo "启用跨AZ负载均衡..."
    if ! aws elbv2 modify-load-balancer-attributes \
        --load-balancer-arn "$NLB_ARN" \
        --attributes Key=load_balancing.cross_zone.enabled,Value=true \
        --region "$REGION" 2>&1; then
        echo "警告: 启用跨AZ负载均衡失败，但继续执行"
    fi
    
    # 等待NLB变为活动状态
    echo "等待NLB变为活动状态..."
    if ! aws elbv2 wait load-balancer-available \
        --load-balancer-arns "$NLB_ARN" \
        --region "$REGION" 2>&1; then
        echo "警告: 等待NLB可用超时，但继续执行"
    fi
}

# 创建监听器
create_listener() {
    echo "创建监听器..."
    
    # 检查监听器是否已存在
    EXISTING_LISTENERS=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$NLB_ARN" \
        --region "$REGION" \
        --query "Listeners[?Port==\`$CONTAINER_PORT\`].ListenerArn" \
        --output text)
    
    if [[ -n "$EXISTING_LISTENERS" && "$EXISTING_LISTENERS" != "None" ]]; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            echo "删除现有监听器..."
            aws elbv2 delete-listener \
                --listener-arn "$EXISTING_LISTENERS" \
                --region "$REGION"
        else
            echo "监听器已存在，跳过创建: $EXISTING_LISTENERS"
            LISTENER_ARN="$EXISTING_LISTENERS"
            return
        fi
    fi
    
    LISTENER_ARN=$(aws elbv2 create-listener \
        --load-balancer-arn "$NLB_ARN" \
        --protocol TCP \
        --port "$CONTAINER_PORT" \
        --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
        --region "$REGION" \
        --query 'Listeners[0].ListenerArn' \
        --output text)
    
    echo "监听器已创建: $LISTENER_ARN"
}

# 更新ECS服务
update_ecs_service() {
    echo "将ECS服务与目标组关联..."
    
    # 检查服务是否已经关联了负载均衡器
    CURRENT_LB=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query "services[0].loadBalancers[?targetGroupArn==\`$TARGET_GROUP_ARN\`].targetGroupArn" \
        --output text)
    
    if [[ -n "$CURRENT_LB" && "$CURRENT_LB" != "None" ]]; then
        echo "ECS服务已关联到目标组，跳过更新"
        return
    fi
    
    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --load-balancers targetGroupArn="$TARGET_GROUP_ARN",containerName="$CONTAINER_NAME",containerPort="$CONTAINER_PORT" \
        --region "$REGION" > /dev/null
    
    echo "ECS服务已关联到目标组"
}

# 获取NLB信息
get_nlb_info() {
    NLB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$NLB_ARN" \
        --region "$REGION" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    echo "NLB DNS名称: $NLB_DNS"
}

# 保存部署信息
save_deployment_info() {
    cat > nlb-info.txt << EOF
部署时间: $(date)
区域: $REGION
VPC ID: $VPC_ID
集群名称: $CLUSTER_NAME
服务名称: $SERVICE_NAME
NLB名称: $NLB_NAME
NLB ARN: $NLB_ARN
NLB DNS: $NLB_DNS
目标组名称: $TARGET_GROUP_NAME
目标组ARN: $TARGET_GROUP_ARN
容器名称: $CONTAINER_NAME
容器端口: $CONTAINER_PORT
访问URL: http://$NLB_DNS:$CONTAINER_PORT
ECS服务子网(私有): $ECS_SUBNETS
NLB子网(公有): $SUBNETS
ECS服务可用区: $ECS_AZS
EOF
    
    echo "部署信息已保存到 nlb-info.txt"
}

# 主函数
main() {
    echo "=== NLB部署脚本开始 ==="
    
    # 解析参数
    parse_arguments "$@"
    
    # 验证参数
    validate_parameters
    
    echo "配置信息:"
    echo "  区域: $REGION"
    echo "  集群: $CLUSTER_NAME"
    echo "  服务: $SERVICE_NAME"
    echo "  NLB名称: $NLB_NAME"
    echo "  目标组名称: $TARGET_GROUP_NAME"
    echo "  强制重建: $FORCE_RECREATE"
    echo ""
    
    # 获取ECS服务信息
    get_ecs_service_info
    
    # 创建资源
    create_target_group
    create_load_balancer
    create_listener
    update_ecs_service
    
    # 获取部署信息
    get_nlb_info
    
    # 保存部署信息
    save_deployment_info
    
    echo ""
    echo "=== NLB部署完成！ ==="
    echo "NLB DNS名称: $NLB_DNS"
    echo "访问URL: http://$NLB_DNS:$CONTAINER_PORT"
}

# 执行主函数
main "$@"

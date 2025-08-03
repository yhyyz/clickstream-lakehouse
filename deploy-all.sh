#!/bin/bash

# Clickstream Lakehouse 通用部署脚本
# 支持两种部署方案：NLB + Nginx + Lua 和 ALB + Nginx + Vector

set -e

# 显示帮助信息
show_help() {
    cat << EOF
Clickstream Lakehouse 通用部署脚本

用法: $0 [方案] [选项]

支持的部署方案:
    nlb     使用 NLB + Nginx + Fluent Bit 方案 (默认)
    alb     使用 ALB + Nginx + Vector 方案

选项:
    -h, --help                   显示此帮助信息
    [其他选项]                   传递给具体部署脚本的参数

示例:
    # 使用 NLB 方案部署
    $0 nlb -b my-bucket -m my-msk-cluster

    # 使用 ALB 方案部署
    $0 alb -b my-bucket -m my-msk-cluster

    # 默认使用 NLB 方案
    $0 -b my-bucket -m my-msk-cluster

    # 查看特定方案的帮助信息
    $0 nlb --help
    $0 alb --help

方案对比:
    NLB + Nginx + Fluent Bit:
        - 网络负载均衡器 (Layer 4)
        - 更高性能，更低延迟
        - 支持TCP/UDP流量
        - 适合高吞吐量场景

    ALB + Nginx + Vector:
        - 应用负载均衡器 (Layer 7)
        - 更丰富的路由功能
        - 支持HTTP/HTTPS流量
        - 更好的可观测性和监控

EOF
}

# 检查第一个参数是否为方案选择
DEPLOYMENT_SCHEME=""
SCRIPT_ARGS=()

# 如果第一个参数是方案名称，则提取它
if [[ $# -gt 0 ]]; then
    case $1 in
        nlb)
            DEPLOYMENT_SCHEME="nlb"
            shift
            ;;
        alb)
            DEPLOYMENT_SCHEME="alb"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            # 如果第一个参数不是方案名称，默认使用 NLB
            DEPLOYMENT_SCHEME="nlb"
            ;;
    esac
else
    # 如果没有参数，显示帮助信息
    show_help
    exit 0
fi

# 收集剩余的参数
SCRIPT_ARGS=("$@")

# 根据选择的方案执行相应的部署脚本
case $DEPLOYMENT_SCHEME in
    nlb)
        echo "=========================================="
        echo "使用 NLB + Nginx + Fluent Bit 方案部署"
        echo "=========================================="
        echo "数据链路: NLB -> ECS (nginx+fluent-bit) -> MSK -> MSK Connector -> Iceberg/S3"
        echo ""
        
        # 检查脚本是否存在
        if [[ ! -f "deploy-nlb-nginx-lua-msk-all.sh" ]]; then
            echo "错误: 找不到 NLB 部署脚本 'deploy-nlb-nginx-lua-msk-all.sh'"
            exit 1
        fi
        
        # 执行 NLB 部署脚本
        exec ./deploy-nlb-nginx-lua-msk-all.sh "${SCRIPT_ARGS[@]}"
        ;;
    alb)
        echo "=========================================="
        echo "使用 ALB + Nginx + Vector 方案部署"
        echo "=========================================="
        echo "数据链路: ALB -> ECS (nginx+vector) -> MSK -> MSK Connector -> Iceberg/S3"
        echo ""
        
        # 检查脚本是否存在
        if [[ ! -f "deploy-alb-nginx-vector-msk-all.sh" ]]; then
            echo "错误: 找不到 ALB 部署脚本 'deploy-alb-nginx-vector-msk-all.sh'"
            exit 1
        fi
        
        # 执行 ALB 部署脚本
        exec ./deploy-alb-nginx-vector-msk-all.sh "${SCRIPT_ARGS[@]}"
        ;;
    *)
        echo "错误: 未知的部署方案 '$DEPLOYMENT_SCHEME'"
        echo "支持的方案: nlb, alb"
        echo ""
        show_help
        exit 1
        ;;
esac

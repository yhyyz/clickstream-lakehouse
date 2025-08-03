# ALB部署

本目录包含ALB+Nginx+Vector方案的应用负载均衡器(ALB)部署配置和脚本。

## 目录结构

```
alb/
├── deploy-alb-optimized.sh         # ALB部署脚本
└── README.md                       # 本文档
```

## ALB架构说明

ALB作为整个方案的入口点，负责：
- 接收来自互联网的HTTP/HTTPS请求
- 将流量分发到ECS服务中的Nginx容器
- 提供健康检查和故障转移
- 支持SSL终止和路径路由

### ALB配置特性

- **类型**: Application Load Balancer
- **协议**: HTTP/HTTPS
- **端口**: 8802 (主要), 80, 443
- **健康检查**: HTTP `/health` 端点
- **目标类型**: IP (Fargate任务)
- **跨AZ**: 自动启用

## 快速部署

```bash
./deploy-alb-optimized.sh \
  --vpc vpc-12345678 \
  --cluster clickstream-alb-cluster \
  --service clickstream-alb-optimized-service
```

## 部署参数

### 部署脚本参数 (deploy-alb-optimized.sh)

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-r, --region` | `us-east-1` | AWS区域 |
| `-v, --vpc` | 自动获取 | VPC ID |
| `-c, --cluster` | `clickstream-alb-cluster` | ECS集群名称 |
| `-s, --service` | `clickstream-alb-optimized-service` | ECS服务名称 |
| `-f, --force` | `false` | 强制重新创建资源 |

## 部署前提条件

### 必需资源
1. **ECS服务**: 必须先部署ECS服务
2. **VPC**: 包含公有子网和私有子网
3. **公有子网**: 至少2个不同AZ的公有子网
4. **互联网网关**: VPC必须有IGW

### 检查ECS服务
```bash
aws ecs describe-services \
  --cluster clickstream-alb-cluster \
  --services clickstream-alb-optimized-service \
  --region us-east-1
```

## 部署过程

脚本执行以下步骤：

1. **ECS服务验证**: 检查目标ECS服务是否存在
2. **网络发现**:
   - 获取ECS服务所在的可用区
   - 查找对应的公有子网
3. **安全组创建**: 创建ALB专用安全组
4. **目标组创建**:
   - 配置健康检查
   - 设置目标类型为IP
5. **ALB创建**:
   - 在公有子网中创建
   - 配置监听器
6. **服务关联**: 将ECS服务关联到目标组

## 网络配置

### 子网要求
- **类型**: 公有子网 (有IGW路由)
- **可用区**: 至少2个AZ
- **自动检测**: 脚本会自动查找公有子网

### 安全组配置
脚本会创建ALB安全组 `clickstream-alb-opti-alb-sg`，但**不会**自动配置规则。

**重要**: 部署完成后必须配置安全组规则：
```bash
cd .. && ./configure-security-groups.sh --vpc <VPC_ID> --msk-cluster <MSK_CLUSTER>
```

### 目标组配置
- **协议**: HTTP
- **端口**: 8802
- **健康检查路径**: `/health`
- **健康检查间隔**: 30秒
- **健康阈值**: 2次成功
- **不健康阈值**: 3次失败

## 部署示例

### 基本部署
```bash
./deploy-alb-optimized.sh --vpc vpc-0e1bd10042a247fdf
```

### 自定义ECS服务部署
```bash
./deploy-alb-optimized.sh \
  --region us-east-1 \
  --vpc vpc-0e1bd10042a247fdf \
  --cluster my-cluster \
  --service my-service
```

### 强制重新创建
```bash
./deploy-alb-optimized.sh \
  --vpc vpc-0e1bd10042a247fdf \
  --force
```

## 部署后验证

### 检查ALB状态
```bash
aws elbv2 describe-load-balancers \
  --names clickstream-alb-opti-alb \
  --region us-east-1
```

### 检查目标组健康状态
```bash
# 获取目标组ARN
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --names clickstream-alb-opti-tg \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region us-east-1)

# 检查目标健康状态
aws elbv2 describe-target-health \
  --target-group-arn $TARGET_GROUP_ARN \
  --region us-east-1
```

### 测试健康检查端点
```bash
# 获取ALB DNS名称
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names clickstream-alb-opti-alb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

# 测试健康检查 (需要先配置安全组规则)
curl http://$ALB_DNS:8802/health
```

## 生成的文件

部署完成后会生成：
- `../tmp/alb-info.json`: ALB详细信息

示例内容：
```json
{
  "deployment_time": "2025-08-02T12:00:00Z",
  "region": "us-east-1",
  "vpc_id": "vpc-12345678",
  "cluster_name": "clickstream-alb-cluster",
  "service_name": "clickstream-alb-optimized-service",
  "alb_name": "clickstream-alb-opti-alb",
  "alb_arn": "arn:aws:elasticloadbalancing:...",
  "alb_dns": "clickstream-alb-opti-alb-123456789.us-east-1.elb.amazonaws.com",
  "target_group_name": "clickstream-alb-opti-tg",
  "target_group_arn": "arn:aws:elasticloadbalancing:...",
  "security_group_id": "sg-12345678",
  "container_name": "nginx-container",
  "container_port": 8802,
  "access_urls": {
    "http": "http://alb-dns:8802",
    "collect_endpoint": "http://alb-dns:8802/collect",
    "ping_endpoint": "http://alb-dns:8802/ping",
    "health_endpoint": "http://alb-dns:8802/health"
  }
}
```

## 访问端点

ALB部署完成后提供以下端点：

| 端点 | 路径 | 用途 |
|------|------|------|
| 数据收集 | `/collect` | 接收点击流数据 |
| 健康检查 | `/health` | 服务健康状态 |
| Ping | `/ping` | 连通性测试 |

### 使用示例

```bash
# 健康检查
curl http://ALB_DNS:8802/health

# Ping测试
curl http://ALB_DNS:8802/ping

# 发送测试数据
curl -X POST http://ALB_DNS:8802/collect \
  -H "Content-Type: application/json" \
  -H "project: app_logs" \
  -d "$(echo '{"test": "data"}' | base64 -w 0)"
```

## 故障排除

### 常见问题

1. **ALB创建失败**
   - 检查公有子网配置
   - 验证IGW路由
   - 确认可用区覆盖

2. **目标组健康检查失败**
   - 检查ECS任务状态
   - 验证安全组规则
   - 确认健康检查路径

3. **无法访问ALB**
   - **首先配置安全组规则**
   - 检查DNS解析
   - 验证监听器配置

4. **ECS服务关联失败**
   - 确认ECS服务存在
   - 检查容器端口配置
   - 验证任务定义

### 安全组配置问题

**最常见的问题**: 忘记配置安全组规则

**解决方案**:
```bash
cd .. && ./configure-security-groups.sh \
  --vpc <VPC_ID> \
  --msk-cluster <MSK_CLUSTER_NAME>
```

这会配置：
- ALB安全组允许外网访问8802端口
- ECS安全组允许ALB访问
- MSK安全组允许ECS访问

### 权限要求

部署脚本需要以下AWS权限：
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:*",
                "ec2:DescribeSubnets",
                "ec2:DescribeRouteTables",
                "ec2:DescribeSecurityGroups",
                "ec2:CreateSecurityGroup",
                "ecs:DescribeServices",
                "ecs:DescribeTaskDefinition",
                "ecs:UpdateService"
            ],
            "Resource": "*"
        }
    ]
}
```

## 监控和日志

### CloudWatch指标
ALB自动提供以下指标：
- 请求数量
- 响应时间
- 错误率
- 目标健康状态

### 访问日志
可以启用ALB访问日志：
```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn <ALB_ARN> \
  --attributes Key=access_logs.s3.enabled,Value=true \
               Key=access_logs.s3.bucket,Value=<S3_BUCKET>
```

## 性能优化

### 连接设置
- **空闲超时**: 60秒 (默认)
- **连接排空**: 300秒 (默认)
- **粘性会话**: 不启用

### 健康检查优化
- 调整检查间隔
- 优化超时设置
- 配置合适的阈值

## SSL/TLS配置

### 添加HTTPS监听器
```bash
aws elbv2 create-listener \
  --load-balancer-arn <ALB_ARN> \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=<CERT_ARN> \
  --default-actions Type=forward,TargetGroupArn=<TARGET_GROUP_ARN>
```

### 证书管理
- 使用AWS Certificate Manager
- 配置域名验证
- 设置自动续期

## 下一步

ALB部署完成后：

1. **配置安全组规则** (必需)
2. **测试健康检查端点**
3. **运行数据流测试** (参见 `../test-data-flow.sh`)
4. **配置监控和告警**
5. **设置SSL证书** (可选)

## 清理资源

删除ALB资源：
```bash
# 删除ALB
aws elbv2 delete-load-balancer \
  --load-balancer-arn <ALB_ARN>

# 删除目标组
aws elbv2 delete-target-group \
  --target-group-arn <TARGET_GROUP_ARN>

# 删除安全组
aws ec2 delete-security-group \
  --group-id <SECURITY_GROUP_ID>
```

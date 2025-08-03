# ECS服务部署

本目录包含ALB+Nginx+Vector方案的ECS服务部署配置和脚本。

## 目录结构

```
ecs/
├── deploy-ecs-optimized.sh         # ECS部署脚本
└── README.md                       # 本文档
```

## 架构说明

ECS服务运行两个容器：
- **Nginx容器**: 接收HTTP请求，提供反向代理
- **Vector容器**: 处理数据并发送到MSK

### 容器配置

#### Nginx容器
- **端口**: 8802 (HTTP服务)
- **健康检查**: `/health` 端点
- **资源**: 2048 CPU, 4096 MB内存
- **功能**: 
  - 接收点击流数据
  - 转发请求到Vector
  - 提供健康检查和ping端点

#### Vector容器
- **端口**: 8685 (HTTP服务), 8686 (健康检查)
- **数据卷**: EBS卷挂载到 `/var/lib/vector`
- **资源**: 6144 CPU, 12288 MB内存
- **功能**:
  - 接收来自Nginx的数据
  - 数据转换和处理
  - 发送到MSK Kafka集群

## 快速部署

```bash
./deploy-ecs-optimized.sh \
  --vpc vpc-12345678 \
  --kafka-broker-host your-kafka.amazonaws.com \
  --desired-count 2
```

## 部署参数

### 部署脚本参数 (deploy-ecs-optimized.sh)

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-r, --region` | `us-east-1` | AWS区域 |
| `-c, --cluster` | `clickstream-alb-cluster` | ECS集群名称 |
| `-t, --task-family` | `clickstream-alb-task-optimized` | 任务定义名称 |
| `-s, --service` | `clickstream-alb-optimized-service` | 服务名称 |
| `-v, --vpc` | 必需 | VPC ID |
| `--subnets` | 自动检测 | 私有子网ID列表 |
| `--security-groups` | 自动创建 | 安全组ID列表 |
| `--desired-count` | `4` | 期望任务数量 |
| `--ebs-size` | `500` | EBS卷大小(GiB) |
| `--kafka-broker-host` | 必需 | Kafka代理主机 |
| `--kafka-broker-port` | `9092` | Kafka代理端口 |
| `--msk-topic` | `app_logs` | MSK主题名称 |

## 部署过程

脚本执行以下步骤：

1. **参数验证**: 检查必需参数
2. **资源检测**: 
   - 自动检测私有子网
   - 获取AWS账户ID
3. **IAM角色创建**:
   - ECS任务执行角色
   - ECS任务角色
   - ECS基础设施角色 (用于EBS卷管理)
4. **基础设施创建**:
   - CloudWatch日志组
   - ECS集群 (如果不存在)
   - 安全组 (如果未指定)
5. **服务部署**:
   - 注册任务定义
   - 创建/更新ECS服务
   - 等待服务稳定

## 环境变量配置

### Nginx容器环境变量
- `SERVER_ENDPOINT_PATH`: `/collect`
- `PING_ENDPOINT_PATH`: `/ping`
- `SERVER_CORS_ORIGIN`: `*`
- `NGINX_WORKER_CONNECTIONS`: `1024`

### Vector容器环境变量
- `AWS_REGION`: 部署区域
- `AWS_MSK_BROKERS`: Kafka代理地址
- `AWS_MSK_TOPIC`: MSK主题名称
- `STREAM_ACK_ENABLE`: `true`
- `VECTOR_REQUIRE_HEALTHY`: `false`
- `WORKER_THREADS_NUM`: `-1` (自动)

## 存储配置

### EBS卷配置
- **卷类型**: gp3
- **大小**: 500 GiB (可配置)
- **IOPS**: 16000
- **吞吐量**: 1000 MB/s
- **文件系统**: ext4
- **挂载点**: `/var/lib/vector`

Vector使用此卷进行：
- 数据缓冲
- 状态持久化
- 故障恢复

## 网络配置

### 子网要求
- **类型**: 私有子网
- **可用区**: 至少2个AZ
- **自动检测**: 脚本会自动查找私有子网

### 安全组
脚本会创建默认安全组 `clickstream-alb-ecs-sg`，但**不会**自动配置规则。

**重要**: 部署完成后必须配置安全组规则：
```bash
cd .. && ./configure-security-groups.sh --vpc <VPC_ID> --msk-cluster <MSK_CLUSTER>
```

## 部署示例

### 基本部署
```bash
./deploy-ecs-optimized.sh \
  --vpc vpc-0e1bd10042a247fdf \
  --kafka-broker-host boot-eo1.msklogstream.oee1gg.c16.kafka.us-east-1.amazonaws.com
```

### 自定义配置部署
```bash
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --vpc vpc-0e1bd10042a247fdf \
  --cluster my-cluster \
  --service my-service \
  --kafka-broker-host boot-eo1.msklogstream.oee1gg.c16.kafka.us-east-1.amazonaws.com \
  --desired-count 2 \
  --ebs-size 1000 \
  --msk-topic my_topic
```

## 部署后验证

### 检查服务状态
```bash
aws ecs describe-services \
  --cluster clickstream-alb-cluster \
  --services clickstream-alb-optimized-service \
  --region us-east-1
```

### 检查任务健康状态
```bash
aws ecs list-tasks \
  --cluster clickstream-alb-cluster \
  --service-name clickstream-alb-optimized-service \
  --region us-east-1
```

### 查看容器日志
```bash
# 查看所有日志
aws logs tail /ecs/clickstream-alb-cluster --follow --region us-east-1

# 查看特定容器日志
aws logs get-log-events \
  --log-group-name /ecs/clickstream-alb-cluster \
  --log-stream-name nginx/nginx-container/<task-id> \
  --region us-east-1
```

## 生成的文件

部署完成后会生成：
- `../tmp/ecs-service-info.json`: ECS服务详细信息

示例内容：
```json
{
  "cluster_name": "clickstream-alb-cluster",
  "service_name": "clickstream-alb-optimized-service",
  "task_family": "clickstream-alb-task-optimized",
  "region": "us-east-1",
  "vpc_id": "vpc-12345678",
  "subnets": "subnet-123,subnet-456",
  "security_groups": "sg-12345678",
  "desired_count": 2,
  "kafka_broker": "my-kafka.amazonaws.com:9092",
  "msk_topic": "app_logs",
  "task_definition_arn": "arn:aws:ecs:...",
  "deployment_time": "2025-08-02T12:00:00Z"
}
```

## 故障排除

### 常见问题

1. **任务启动失败**
   - 检查Docker镜像是否存在
   - 验证IAM角色权限
   - 查看CloudWatch日志

2. **健康检查失败**
   - 确认容器端口配置
   - 检查安全组规则
   - 验证容器启动脚本

3. **EBS卷挂载失败**
   - 检查ECS基础设施角色权限
   - 验证可用区配置
   - 确认EBS配额

4. **网络连接问题**
   - 检查子网路由表
   - 验证NAT网关配置
   - 确认安全组规则

### 权限要求

部署脚本需要以下AWS权限：
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecs:*",
                "iam:CreateRole",
                "iam:AttachRolePolicy",
                "iam:PutRolePolicy",
                "iam:GetRole",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:CreateSecurityGroup",
                "logs:CreateLogGroup",
                "logs:DescribeLogGroups"
            ],
            "Resource": "*"
        }
    ]
}
```

## 性能调优

### 资源配置建议

| 负载级别 | 任务数量 | CPU | 内存 | EBS大小 |
|----------|----------|-----|------|---------|
| 轻量 | 2 | 4096 | 8192 | 200GB |
| 中等 | 4 | 8192 | 16384 | 500GB |
| 重载 | 8+ | 16384 | 32768 | 1000GB+ |

### Vector配置优化
- 调整批处理大小
- 配置缓冲区设置
- 优化线程数量

## 下一步

ECS服务部署完成后：

1. **部署ALB** (参见 `../alb/README.md`)
2. **配置安全组规则** (必需)
3. **测试数据流** (参见 `../test-data-flow.sh`)
4. **监控和告警设置**

## 清理资源

删除ECS服务：
```bash
# 停止服务
aws ecs update-service \
  --cluster clickstream-alb-cluster \
  --service clickstream-alb-optimized-service \
  --desired-count 0 \
  --region us-east-1

# 删除服务
aws ecs delete-service \
  --cluster clickstream-alb-cluster \
  --service clickstream-alb-optimized-service \
  --region us-east-1

# 删除任务定义 (可选)
aws ecs deregister-task-definition \
  --task-definition clickstream-alb-task-optimized:1 \
  --region us-east-1
```

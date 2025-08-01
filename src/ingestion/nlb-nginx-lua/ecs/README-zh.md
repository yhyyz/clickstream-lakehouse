# ECS 点击流部署

此目录包含用于点击流处理服务的优化ECS部署脚本。

## 功能特性

- **参数化部署**：支持不同的区域、VPC和环境
- **自动资源创建**：根据需要创建IAM角色、安全组和S3存储桶
- **VPC子网自动检测**：自动查找指定VPC中的私有子网
- **健康检查**：Nginx容器包含`/health`端点的健康检查
- **跨账户支持**：自动检测账户ID用于ECR镜像URL
- **环境特定配置**：所有硬编码值替换为变量

## 前置条件

- 配置了适当权限的AWS CLI
- Docker镜像已推送到ECR：
  - `clickstream-openresty-lua-msk-optimized:latest`
  - `custom-fluent-bit-optimized:latest`

## 快速开始

### 基础部署

```bash
./deploy-ecs-optimized.sh \
  --s3-bucket my-clickstream-logs \
  --vpc vpc-12345678 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

### 高级部署

```bash
./deploy-ecs-optimized.sh \
  --region us-west-2 \
  --cluster my-clickstream-cluster \
  --s3-bucket my-clickstream-logs \
  --vpc vpc-12345678 \
  --subnets subnet-123,subnet-456 \
  --security-groups sg-789 \
  --desired-count 2 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

## 参数说明

| 参数 | 必需 | 默认值 | 描述 |
|------|------|--------|------|
| `--region` | 否 | us-east-1 | AWS区域 |
| `--cluster` | 否 | clickstream-cluster | ECS集群名称 |
| `--task-family` | 否 | clickstream-task-optimized | 任务定义族名称 |
| `--service` | 否 | clickstream-optimized-service | 服务名称 |
| `--s3-bucket` | **是** | - | 用于数据存储的S3存储桶 |
| `--vpc` | **是** | - | 部署的VPC ID |
| `--subnets` | 否 | 自动检测 | 逗号分隔的子网ID |
| `--security-groups` | 否 | 自动创建 | 逗号分隔的安全组ID |
| `--desired-count` | 否 | 4 | 要运行的任务数量 |
| `--ebs-size` | 否 | 500 | EBS卷大小（GiB） |
| `--kafka-broker-host` | **是** | - | Kafka代理主机名 |
| `--kafka-broker-port` | 否 | 9092 | Kafka代理端口 |

## 脚本执行内容

1. **验证参数**并显示配置
2. **创建IAM角色**（如果不存在）：
   - ECS任务执行角色
   - ECS任务角色（具有S3和CloudWatch权限）
   - ECS基础设施角色（用于EBS卷管理）
3. **创建S3存储桶**并启用版本控制
4. **创建CloudWatch日志组**用于容器日志
5. **创建ECS集群**（如果不存在）
6. **自动检测私有子网**在指定的VPC中（如果未提供）
7. **创建默认安全组**（如果未提供）
8. **生成配置文件**并进行适当的变量替换
9. **注册任务定义**并配置健康检查
10. **创建或更新ECS服务**
11. **等待服务稳定**

## 健康检查

nginx容器包含健康检查，具体配置：
- 检查`http://localhost:8802/health`端点
- 每30秒运行一次
- 5秒超时
- 允许3次重试
- 60秒启动宽限期

## 安全性

- **无公网IP分配**：任务仅在私有子网中运行
- **最小权限IAM角色**：具有最小必需权限的自定义角色
- **VPC安全组**：通过安全组控制网络访问

## 故障排除

### 查看部署帮助
```bash
./deploy-ecs-optimized.sh --help
```

### 检查服务状态
```bash
aws ecs describe-services \
  --cluster clickstream-cluster \
  --services clickstream-optimized-service \
  --region us-east-1
```

### 查看容器日志
```bash
aws logs tail /ecs/clickstream-cluster --follow --region us-east-1
```

### 检查任务健康状态
```bash
aws ecs describe-tasks \
  --cluster clickstream-cluster \
  --tasks $(aws ecs list-tasks --cluster clickstream-cluster --service-name clickstream-optimized-service --query 'taskArns[0]' --output text) \
  --region us-east-1
```

## 文件说明

- `deploy-ecs-optimized.sh`：主部署脚本


## 使用示例

### 在生产环境中部署
```bash
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --cluster production-clickstream \
  --s3-bucket production-clickstream-data \
  --vpc vpc-prod123456 \
  --desired-count 6 \
  --kafka-broker-host prod-kafka.internal.company.com
```

### 在测试环境中部署
```bash
./deploy-ecs-optimized.sh \
  --region us-west-2 \
  --cluster test-clickstream \
  --s3-bucket test-clickstream-data \
  --vpc vpc-test789012 \
  --desired-count 2 \
  --kafka-broker-host test-kafka.internal.company.com
```

### 使用自定义子网和安全组
```bash
./deploy-ecs-optimized.sh \
  --s3-bucket my-clickstream-data \
  --vpc vpc-12345678 \
  --subnets subnet-private1,subnet-private2 \
  --security-groups sg-custom123 \
  --kafka-broker-host kafka.example.com
```

## 注意事项

- 如果未指定子网，脚本将自动查找指定VPC中的私有子网
- 如果未指定安全组，将创建默认安全组
- 脚本将在不存在时创建必要的IAM角色
- 如果ECS集群不存在，将创建ECS集群
- 所有资源都使用一致的命名约定以便于管理

## 支持的AWS服务

此脚本与以下AWS服务集成：
- **Amazon ECS**：容器编排
- **Amazon ECR**：容器镜像注册表
- **Amazon S3**：数据存储
- **Amazon VPC**：网络隔离
- **AWS IAM**：访问管理
- **Amazon CloudWatch**：日志记录和监控
- **Amazon EBS**：持久存储

# Clickstream Lakehouse 点击流数据湖解决方案

这是一个基于AWS服务构建的完整点击流数据湖解决方案，支持实时数据采集、流式处理和数据湖存储。

## 架构概览

```
用户请求 -> NLB -> ECS (Nginx + Fluent Bit) -> MSK -> MSK Connector -> Iceberg/S3
```

### 数据链路说明

1. **NLB (Network Load Balancer)**: 接收用户的点击流请求
2. **ECS (Elastic Container Service)**: 运行Nginx和Fluent Bit容器处理请求
3. **MSK (Managed Streaming for Apache Kafka)**: 作为消息队列缓冲数据
4. **MSK Connector**: 将Kafka数据写入到数据湖
5. **Iceberg/S3**: 最终的数据湖存储

## 项目结构

```
clickstream-lakehouse/
├── deploy-all.sh                    # 统一部署脚本
├── test-data-flow.sh               # 数据流测试脚本
├── example-deploy.sh               # 部署示例脚本
├── test-example.sh                 # 测试示例脚本
├── README.md                        # 本文档
├── prompt.md                        # 项目需求说明
└── src/
    ├── ingestion/                   # 数据采集组件
    │   └── nlb-nginx-lua/
    │       ├── docker/              # Docker镜像构建
    │       ├── ecs/                 # ECS服务部署
    │       └── nlb/                 # 负载均衡器部署
    └── msk-iceberg/                 # MSK和Iceberg连接器
        ├── create-msk-topics.sh     # 创建MSK主题
        ├── create-s3-iceberg-connector-optimized.sh  # Iceberg连接器
        └── create-s3-json-connector-optimized.sh     # S3连接器
```

## 前置条件

### AWS服务要求

1. **AWS CLI** 已配置并具有以下权限：
   - ECS: 创建集群、服务、任务定义
   - ECR: 创建仓库、推送镜像
   - IAM: 创建角色和策略
   - VPC: 访问子网、安全组
   - S3: 创建和管理存储桶
   - MSK: 管理Kafka集群和连接器
   - CloudWatch: 创建日志组
   - Glue: 管理数据目录

2. **Docker** 已安装并运行

3. **已创建的AWS资源**：
   - VPC和私有子网
   - MSK集群（已运行状态）
   - S3存储桶（用于数据存储）

### 本地环境

- Linux/macOS 环境
- Bash shell
- 网络连接到AWS

## 快速开始

### 1. 完整部署

使用统一部署脚本一键部署整个解决方案：

```bash
./deploy-all.sh \
  --s3-bucket my-clickstream-bucket \
  --msk-cluster my-msk-cluster \
  --region us-east-1
```

### 2. 分阶段部署

如果需要分阶段部署或跳过某些步骤：

```bash
# 跳过Docker镜像构建（如果镜像已存在）
./deploy-all.sh \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --skip-docker

# 只部署MSK相关组件
./deploy-all.sh \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --skip-docker --skip-ecs --skip-nlb

# 手动指定VPC（如果自动检测失败）
./deploy-all.sh \
  --s3-bucket my-bucket \
  --vpc vpc-12345678 \
  --msk-cluster my-cluster
```

### 3. 查看部署计划

使用dry-run模式查看将要执行的操作：

```bash
./deploy-all.sh \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --dry-run
```

## 详细配置参数

### 必需参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `--s3-bucket` | S3存储桶名称 | `my-clickstream-bucket` |
| `--msk-cluster` | MSK集群名称 | `my-msk-cluster` |

### 可选参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--region` | `us-east-1` | AWS区域 |
| `--vpc` | 自动获取 | VPC ID（如果不指定，将从MSK集群自动获取） |
| `--glue-database` | `iceberg_db` | Glue数据库名称 |
| `--desired-count` | `4` | ECS任务数量 |
| `--worker-count` | `6` | MSK连接器Worker数量 |

### 部署阶段控制

| 参数 | 说明 |
|------|------|
| `--skip-docker` | 跳过Docker镜像构建 |
| `--skip-ecs` | 跳过ECS部署 |
| `--skip-nlb` | 跳过NLB部署 |
| `--skip-msk-topics` | 跳过MSK主题创建 |
| `--skip-iceberg-connector` | 跳过Iceberg连接器创建 |
| `--skip-s3-connector` | 跳过S3连接器创建 |

## 手动部署步骤

如果需要手动执行各个步骤，可以按以下顺序进行：

### 1. 构建Docker镜像

```bash
cd src/ingestion/nlb-nginx-lua/docker
./build-all-images.sh --region us-east-1
```

### 2. 部署ECS服务

```bash
cd src/ingestion/nlb-nginx-lua/ecs
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --s3-bucket my-clickstream-bucket \
  --vpc vpc-12345678 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

### 3. 部署网络负载均衡器

```bash
cd src/ingestion/nlb-nginx-lua/nlb
./deploy-nlb-optimized.sh \
  --region us-east-1 \
  --vpc vpc-12345678
```

### 4. 创建MSK主题

```bash
cd src/msk-iceberg
./create-msk-topics.sh --cluster-name my-msk-cluster
```

### 5. 创建Iceberg连接器

```bash
cd src/msk-iceberg
./create-s3-iceberg-connector-optimized.sh my-bucket my-msk-cluster
```

### 6. 创建S3连接器

```bash
cd src/msk-iceberg
./create-s3-json-connector-optimized.sh my-bucket my-msk-cluster
```

## 部署后验证

### 1. 检查ECS服务状态

```bash
aws ecs describe-services \
  --cluster clickstream-cluster \
  --services clickstream-optimized-service \
  --region us-east-1
```

### 2. 检查NLB状态

```bash
aws elbv2 describe-load-balancers \
  --names clickstream-optimized-service-nlb \
  --region us-east-1
```

### 3. 检查MSK连接器状态

```bash
aws kafkaconnect list-connectors --region us-east-1
```

### 4. 查看容器日志

```bash
aws logs tail /ecs/clickstream-cluster --follow --region us-east-1
```

## 生成的信息文件

部署完成后，会在相应目录生成以下信息文件：

- `src/ingestion/nlb-nginx-lua/nlb/nlb-info.txt` - NLB信息
- `src/msk-iceberg/msk-topics-info.json` - MSK主题信息
- `src/msk-iceberg/msk-iceberg-connector-info.json` - Iceberg连接器信息
- `src/msk-iceberg/msk-s3-json-connector-info.json` - S3连接器信息

## 数据流测试

### 使用测试脚本

项目提供了专门的测试脚本 `test-data-flow.sh` 来验证部署后的数据链路：

```bash
# 基本测试（使用默认参数）
./test-data-flow.sh

# 指定项目名称和消息数量
./test-data-flow.sh --project my_topic --count 50

# 指定区域和NLB名称
./test-data-flow.sh --region us-west-2 --nlb-name my-nlb

# 高频测试
./test-data-flow.sh --count 100 --interval 0.1
```

#### 测试脚本参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--region` | `us-east-1` | AWS区域 |
| `--nlb-name` | `clickstream-optimized-service-nlb` | NLB名称 |
| `--project` | `app_logs` | 项目名称/MSK主题名称 |
| `--count` | `10` | 发送测试消息数量 |
| `--interval` | `1` | 消息发送间隔（秒） |

#### 测试数据特征

- **数据格式**: JSON格式，包含完整的点击流事件信息
- **数据编码**: 发送前进行Base64编码
- **请求头**: 包含 `project` header，值为指定的项目名称
- **目标主题**: 数据会发送到指定的MSK主题（默认：app_logs）

### 手动发送测试数据

如果需要手动发送测试请求：

```bash
# 获取NLB DNS名称
NLB_DNS=$(aws elbv2 describe-load-balancers \
  --names clickstream-optimized-service-nlb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

# 准备测试数据
TEST_DATA='{"event": "page_view", "user_id": "test123", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'

# Base64编码
ENCODED_DATA=$(echo -n "$TEST_DATA" | base64 -w 0)

# 发送请求
curl -X POST "http://$NLB_DNS:8802/collect" \
  -H "Content-Type: application/json" \
  -H "project: app_logs" \
  -d "$ENCODED_DATA"
```

### 验证数据流

1. **检查Kafka主题**：
```bash
# 使用MSK客户端检查主题中的消息
# 注意：数据会发送到指定的项目主题（默认：app_logs）
```

2. **检查S3存储**：
```bash
aws s3 ls s3://your-bucket/topics/app_logs/ --recursive
```

3. **检查Iceberg表**：
```bash
# 通过Athena或Spark查询Iceberg表
```

### 测试脚本输出示例

```
==========================================
Clickstream Lakehouse 数据流测试
==========================================
AWS区域: us-east-1
NLB名称: clickstream-optimized-service-nlb
项目名称: app_logs
消息数量: 10
发送间隔: 1秒
数据编码: Base64
==========================================
NLB DNS: my-nlb-123456789.elb.us-east-1.amazonaws.com
测试端点: http://my-nlb-123456789.elb.us-east-1.amazonaws.com:8802/collect

发送消息 1/10... ✓ 成功 (HTTP 200)
发送消息 2/10... ✓ 成功 (HTTP 200)
...
==========================================
测试完成!
==========================================
总消息数: 10
成功发送: 10
发送失败: 0
成功率: 100%
项目名称: app_logs
数据编码: Base64
```

## 故障排除

### 常见问题

1. **Docker镜像构建失败**
   - 检查Docker是否运行
   - 确认AWS CLI权限
   - 检查ECR仓库权限

2. **ECS任务启动失败**
   - 检查IAM角色权限
   - 验证VPC和子网配置
   - 查看CloudWatch日志

3. **MSK连接器创建失败**
   - 确认MSK集群状态
   - 检查S3存储桶权限
   - 验证Glue数据库存在

4. **网络连接问题**
   - 检查安全组规则
   - 验证子网路由表
   - 确认NLB健康检查

### 日志查看

```bash
# ECS容器日志
aws logs tail /ecs/clickstream-cluster --follow

# MSK连接器日志
aws logs tail /aws/mskconnect/connector-name --follow

# CloudFormation事件（如果使用）
aws cloudformation describe-stack-events --stack-name your-stack
```

## 清理资源

要删除部署的资源，需要按相反顺序进行：

1. 删除MSK连接器
2. 删除ECS服务和任务定义
3. 删除NLB和目标组
4. 删除ECR镜像
5. 清理S3存储桶（可选）

```bash
# 删除ECS服务
aws ecs update-service \
  --cluster clickstream-cluster \
  --service clickstream-optimized-service \
  --desired-count 0

aws ecs delete-service \
  --cluster clickstream-cluster \
  --service clickstream-optimized-service

# 删除MSK连接器
aws kafkaconnect delete-connector --connector-arn <connector-arn>
```

## 成本优化建议

1. **ECS任务数量**：根据实际负载调整`desired-count`
2. **MSK实例类型**：选择合适的实例类型和数量
3. **S3存储类别**：使用生命周期策略管理数据
4. **CloudWatch日志保留**：设置合理的日志保留期

## 安全最佳实践

1. **网络隔离**：使用私有子网部署ECS任务
2. **IAM权限**：遵循最小权限原则
3. **数据加密**：启用S3和MSK的加密
4. **访问控制**：使用安全组限制网络访问

## 监控和告警

建议设置以下监控指标：

- ECS任务健康状态
- NLB目标健康状态
- MSK集群指标
- MSK连接器状态
- S3存储使用量

## 扩展和定制

### 自定义配置

- 修改Nginx配置：编辑`src/ingestion/nlb-nginx-lua/docker/nginx-for-lua/`下的配置文件
- 调整Fluent Bit配置：修改`src/ingestion/nlb-nginx-lua/docker/fluent-bit/`下的配置
- 自定义Iceberg表结构：修改连接器配置

### 性能调优

- 调整Kafka分区数量
- 优化ECS任务资源配置
- 调整MSK连接器并发度

## 支持和贡献

如有问题或建议，请：

1. 检查本文档的故障排除部分
2. 查看生成的信息文件
3. 检查AWS服务控制台中的状态

## 版本历史

- v1.0: 初始版本，支持基本的点击流数据湖功能
- 包含NLB、ECS、MSK、Iceberg连接器的完整部署

---

**注意**: 本解决方案会产生AWS费用，请根据实际需求调整资源配置，并及时清理不需要的资源。

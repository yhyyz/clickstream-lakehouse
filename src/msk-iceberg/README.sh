# MSK Connector 部署脚本使用文档

本文档介绍如何使用提供的脚本在不同AWS账号和region中部署MSK Connector。脚本会自动从MSK集群获取网络配置和broker地址。

## 脚本概述

提供了两个脚本：
1. `create-iceberg-connector.sh` - 创建MSK到Iceberg的sink connector
2. `create-s3-json-connector.sh` - 创建MSK到S3 JSON的sink connector

## 前置条件

### 1. AWS CLI配置
确保AWS CLI已正确配置，具有足够的权限：
```bash
aws configure
```

### 2. 必需的AWS权限
执行脚本的IAM用户/角色需要以下权限：
- `kafkaconnect:*`
- `kafka:DescribeCluster`
- `kafka:GetBootstrapBrokers`
- `iam:CreateRole`
- `iam:AttachRolePolicy`
- `iam:GetRole`
- `s3:*`
- `glue:CreateDatabase`
- `logs:CreateLogGroup`
- `sts:GetCallerIdentity`

### 3. 系统要求
- 需要安装 `jq` 命令用于JSON解析
- 需要 `wget` 命令用于下载插件

### 4. 网络要求
- MSK集群必须已存在并处于ACTIVE状态
- 脚本会自动使用MSK集群的VPC、子网和安全组配置

## 脚本使用方法

### Iceberg Connector

```bash
./create-iceberg-connector.sh <region> <s3-bucket> <msk-cluster-name> [glue-database] [topic-name]
```

**参数说明：**
- `region`: AWS区域 (必需)
- `s3-bucket`: S3存储桶名称 (必需)
- `msk-cluster-name`: MSK集群名称 (必需) - 脚本会自动获取集群的网络配置和broker地址
- `glue-database`: Glue数据库名称 (可选，默认: iceberg_db)
- `topic-name`: Kafka主题名称 (可选，默认: app_logs)

**示例：**
```bash
./create-iceberg-connector.sh ap-southeast-1 pcd-01 my-msk-cluster iceberg_db app_logs
```

### S3 JSON Connector

```bash
./create-s3-json-connector.sh <region> <s3-bucket> <msk-cluster-name> [topic-name]
```

**参数说明：**
- `region`: AWS区域 (必需)
- `s3-bucket`: S3存储桶名称 (必需)
- `msk-cluster-name`: MSK集群名称 (必需) - 脚本会自动获取集群的网络配置和broker地址
- `topic-name`: Kafka主题名称 (可选，默认: app_logs)

**示例：**
```bash
./create-s3-json-connector.sh ap-southeast-1 pcd-01 my-msk-cluster app_logs
```

## 脚本功能

### 自动发现MSK集群配置
脚本会自动从指定的MSK集群获取以下信息：
- Bootstrap broker地址
- VPC安全组
- VPC子网
- 集群ARN

### 自动创建的资源

两个脚本都会自动创建以下资源（如果不存在）：

1. **CloudWatch日志组**: `msk-connector-log`
2. **IAM角色**: `MSKConnectServiceRole-<region>`，附加以下策略：
   - AmazonMSKFullAccess
   - AWSGlueConsoleFullAccess
   - AmazonS3FullAccess
3. **MSK Connect自定义插件**:
   - Iceberg: `msk-iceberg-sink-plugin`
   - S3: `msk-s3-sink-plugin`
4. **Worker配置**:
   - Iceberg: `sink-iceberg-worker-conf`
   - S3: `msk-connector-s3-sink-config`

### Iceberg特有资源
- **Glue数据库**: 默认为`iceberg_db`，可通过参数自定义

## 配置详情

### Iceberg Connector配置
- **数据格式**: 支持schema演化
- **分区策略**: 按天分区 (`day(meta_ctime)`)
- **存储位置**: `s3://<bucket>/app-logs-data-v1/`
- **控制主题**: `control-iceberg`
- **提交间隔**: 120秒

### S3 JSON Connector配置
- **数据格式**: JSON格式，gzip压缩
- **分区策略**: 基于时间分区 (YYYYMMDD)
- **存储位置**: `s3://<bucket>/app-logs-json-data-v1/`
- **轮转间隔**: 120秒
- **批次大小**: 60000条记录

## 监控和日志

- **CloudWatch日志**: 所有connector日志都发送到`msk-connector-log`日志组
- **错误日志**: S3 connector启用了错误日志记录

## 故障排除

### 常见问题

1. **MSK集群不存在**
   ```
   Error: MSK cluster 'cluster-name' not found in region us-east-1
   ```
   - 检查集群名称是否正确
   - 确认集群在指定region中存在
   - 确认集群状态为ACTIVE

2. **权限不足**
   - 确保执行脚本的IAM用户有足够权限
   - 检查MSK Connect服务角色权限
   - 确认有kafka:DescribeCluster和kafka:GetBootstrapBrokers权限

3. **jq命令未找到**
   ```bash
   # Amazon Linux/CentOS/RHEL
   sudo yum install jq
   
   # Ubuntu/Debian
   sudo apt-get install jq
   
   # macOS
   brew install jq
   ```

4. **插件下载失败**
   - 检查网络连接
   - 验证S3存储桶权限

5. **Glue数据库创建失败**
   - 确保有Glue权限
   - 检查数据库名称是否符合规范

### 检查部署状态

```bash
# 检查MSK集群状态
aws kafka describe-cluster --cluster-name <cluster-name> --region <region>

# 检查connector状态
aws kafkaconnect list-connectors --region <region>

# 检查特定connector详情
aws kafkaconnect describe-connector --connector-arn <connector-arn> --region <region>

# 检查CloudWatch日志
aws logs describe-log-groups --log-group-name-prefix msk-connector-log --region <region>
```

## 清理资源

如需删除创建的connector：

```bash
# 删除connector
aws kafkaconnect delete-connector --connector-arn <connector-arn> --region <region>

# 删除自定义插件（可选）
aws kafkaconnect delete-custom-plugin --custom-plugin-arn <plugin-arn> --region <region>

# 删除worker配置（可选）
aws kafkaconnect delete-worker-configuration --worker-configuration-arn <worker-config-arn> --region <region>
```

## 注意事项

1. **成本考虑**: MSK Connect按MCU和worker数量计费
2. **数据一致性**: 确保Kafka主题数据格式与connector配置匹配
3. **扩展性**: 可根据数据量调整worker数量和MCU配置
4. **安全性**: 建议在生产环境中使用更细粒度的IAM权限
5. **网络配置**: Connector会自动使用MSK集群的网络配置，确保网络连通性

## 支持

如遇到问题，请检查：
1. MSK集群状态和网络配置
2. AWS CloudWatch日志
3. MSK Connect控制台状态
4. IAM权限配置
5. jq和wget命令是否可用

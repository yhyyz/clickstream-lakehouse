# MSK Iceberg 点击流数据湖项目

这个项目提供了一套完整的脚本工具，用于在AWS环境中构建基于MSK (Amazon Managed Streaming for Apache Kafka) 和 Iceberg 的点击流数据湖解决方案。

## 项目概述

该项目包含以下核心组件：
- **MSK Topic 管理**：自动创建需要Kafka主题
- **Iceberg连接器**：将Kafka数据流式写入Iceberg表格
- **S3 JSON连接器**：将Kafka数据以JSON格式存储到S3

## 文件说明

### 核心脚本

| 文件名 | 功能描述 |
|--------|----------|
| `create-msk-topics.sh` | 创建MSK主题的主脚本，支持应用数据主题和控制主题 |
| `create-s3-iceberg-connector-optimized.sh` | 创建MSK到Iceberg的连接器，用于实时数据湖写入 |
| `create-s3-json-connector-optimized.sh` | 创建MSK到S3的JSON连接器，用于数据备份 |

## 快速开始

### 前置条件

1. **AWS CLI** 已配置并有相应权限
2. **Docker** 已安装并运行
3. **MSK集群** 已创建并运行
4. **S3存储桶** 已创建（用于存储plugin插件）

### 1. 创建MSK主题

```bash
# 基本用法 - 使用MSK集群名称
./create-msk-topics.sh --cluster-name my-msk-cluster

# 或者直接指定bootstrap servers
./create-msk-topics.sh broker1:9092,broker2:9092,broker3:9092

# 自定义配置
./create-msk-topics.sh \
  --cluster-name my-msk-cluster \
  --app-topic clickstream_data \
  --control-topic iceberg_control \
  --app-partitions 24 \
  --control-partitions 30 \
  --force
  
# 如果手动创建，可以执行如下,第一个topic app_logs 是点击流数据写入的topic, 第二个topic是msk connector 写iceberg时存储offset的topic
# 创clickstream topic  app-logs
bs="xxxx:9092"
./bin/kafka-topics.sh --create --bootstrap-server ${bs}  --replication-factor 3 --partitions 18 --topic app_logs

# 写iceberg时，offset的存储，解释：https://github.com/databricks/iceberg-kafka-connect/tree/main?tab=readme-ov-file#control-topic
bs="xxxx:9092"
./bin/kafka-topics.sh  \
  --bootstrap-server ${bs} \
  --create \
  --topic control-iceberg \
  --partitions 25
```

### 2. 创建Iceberg连接器
* 下面两个参数是必选的， 更多参数支持可以直接执行脚本 --help 查看， 比如默认分区时间字段，是ecs服务器收到消息的时间，如果想要使用Kafka中的每条记录元数据时间(当生产者写数据到Kafak, kafka自己有元数据记录这条数据的时间)，可以指定 -p 参数选择。
```bash
# 创建Iceberg连接器用于实时数据湖
./create-s3-iceberg-connector-optimized.sh <s3-bucket> <msk-cluster-name>
```

### 3. 创建S3 JSON连接器

```bash
# 创建S3 JSON连接器 
./create-s3-json-connector-optimized.sh <s3-bucket> <msk-cluster-name>
```

## 配置参数

### 默认配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 应用主题名称 | `app_logs` | 点击流数据主题 |
| 控制主题名称 | `control-iceberg` | Iceberg连接器控制主题 |
| 应用主题分区 | `18` | 应用数据分区数 |
| 控制主题分区 | `25` | 控制主题分区数 |
| 副本因子 | `3` | 数据副本数量 |
| Worker数量 | `6` | 连接器Worker数量 |
| MCU数量 | `1` | 每个Worker的MCU |

## 输出文件

脚本执行后会生成相应的信息文件：

- `msk-topics-info.json` - 主题创建信息
- `msk-iceberg-connector-info.json` - Iceberg连接器信息  
- `msk-s3-json-connector-info.json` - S3连接器信息



# ALB+Nginx+Vector 项目结构

本文档描述了ALB+Nginx+Vector点击流数据采集方案的完整项目结构和部署流程。

## 项目目录结构

```
alb-nginx-vector/
├── PROJECT_STRUCTURE.md           # 本文档
├── README.md                       # 主要文档
├── configure-security-groups.sh   # 安全组规则配置脚本
├── test-data-flow.sh               # 数据流测试脚本
├── tmp/                            # 临时文件和部署信息
│   ├── docker-images-info.json    # Docker镜像信息
│   ├── ecs-service-info.json       # ECS服务信息
│   ├── alb-info.json               # ALB信息
│   └── security-groups-info.json  # 安全组配置信息
├── docker/                         # Docker镜像构建
│   ├── README.md                   # Docker构建文档
│   ├── build-all-images.sh        # 镜像构建脚本
│   ├── nginx/                      # Nginx镜像配置
│   │   ├── Dockerfile
│   │   └── config/
│   │       ├── nginx.conf
│   │       └── docker-entrypoint.sh
│   └── vector/                     # Vector镜像配置
│       ├── Dockerfile
│       └── config/
│           ├── entrypoint.sh
│           ├── vector.toml
│           ├── vector-global.toml
│           ├── vector-msk-ack.toml
│           └── vector-msk-batch.toml
├── ecs/                            # ECS服务部署
│   ├── README.md                   # ECS部署文档
│   └── deploy-ecs-optimized.sh     # ECS部署脚本
└── alb/                            # ALB部署
    ├── README.md                   # ALB部署文档
    └── deploy-alb-optimized.sh     # ALB部署脚本
```

## 组件说明

### 1. Docker镜像 (`docker/`)

**功能**: 构建Nginx和Vector的Docker镜像并推送到ECR

**主要文件**:
- `build-all-images.sh`: 一键构建所有镜像
- `nginx/`: Nginx反向代理配置
- `vector/`: Vector数据处理配置

**镜像特性**:
- **Nginx**: 接收HTTP请求，转发到Vector，提供健康检查
- **Vector**: 数据处理和转换，发送到MSK Kafka

### 2. ECS服务 (`ecs/`)

**功能**: 在ECS Fargate上运行Nginx+Vector容器

**主要文件**:
- `deploy-ecs-optimized.sh`: ECS部署脚本，完整功能

**服务特性**:
- **运行模式**: Fargate
- **容器**: Nginx + Vector (共享任务)
- **存储**: EBS卷用于Vector数据缓存
- **网络**: 私有子网，通过NAT网关访问外网

### 3. ALB负载均衡器 (`alb/`)

**功能**: 提供外网访问入口，分发流量到ECS服务

**主要文件**:
- `deploy-alb-optimized.sh`: ALB部署脚本

**ALB特性**:
- **类型**: Application Load Balancer
- **网络**: 公有子网，面向互联网
- **健康检查**: HTTP `/health` 端点
- **端口**: 8802 (主要), 80, 443

### 4. 安全组配置 (`configure-security-groups.sh`)

**功能**: 配置网络安全组规则，确保组件间连通性

**配置规则**:
- **ALB安全组**: 允许外网访问8802端口
- **ECS安全组**: 允许ALB访问，允许内部通信
- **MSK安全组**: 允许ECS访问Kafka端口

### 5. 数据流测试 (`test-data-flow.sh`)

**功能**: 验证完整数据链路的连通性

**测试流程**:
1. 生成测试数据
2. 发送到ALB端点
3. 验证HTTP响应
4. 统计成功率

## 部署流程

### 完整部署顺序

```bash
# 1. 构建Docker镜像
cd docker
./build-all-images.sh --region us-east-1

# 2. 部署ECS服务
cd ../ecs
./deploy-ecs-optimized.sh \
  --vpc vpc-12345678 \
  --kafka-broker-host your-kafka.amazonaws.com

# 3. 部署ALB
cd ../alb
./deploy-alb-optimized.sh --vpc vpc-12345678

# 4. 配置安全组规则 (关键步骤!)
cd ..
./configure-security-groups.sh \
  --vpc vpc-12345678 \
  --msk-cluster your-msk-cluster

# 5. 测试数据流
./test-data-flow.sh --count 10
```

### 部署脚本特性

#### 部署脚本 (`deploy-ecs-optimized.sh`, `deploy-alb-optimized.sh`)
- **完整功能**: 支持所有配置参数
- **自动检测**: 智能检测AWS资源
- **幂等性**: 可重复执行，不会重复创建资源
- **详细日志**: 完整的执行过程记录
- **参数验证**: 检查必需参数和权限
- **错误处理**: 清晰的错误信息和建议

## 数据流架构

```
Internet → ALB → ECS(Nginx+Vector) → MSK → Data Lake
```

### 数据流说明

1. **用户请求**: 通过ALB的8802端口发送HTTP POST请求
2. **负载均衡**: ALB将请求分发到健康的ECS任务
3. **请求处理**: Nginx接收请求并转发给Vector
4. **数据处理**: Vector处理数据并发送到MSK Kafka
5. **数据存储**: MSK Connector将数据写入数据湖

### 端点说明

| 端点 | 路径 | 用途 |
|------|------|------|
| 数据收集 | `/collect` | 接收点击流数据 |
| 健康检查 | `/health` | 服务健康状态检查 |
| Ping测试 | `/ping` | 连通性测试 |

## 网络架构

### 子网配置
- **公有子网**: ALB部署，有IGW路由
- **私有子网**: ECS服务部署，通过NAT网关访问外网

### 安全组规则
- **ALB → Internet**: 允许8802端口入站
- **ECS ← ALB**: 允许ALB访问ECS容器端口
- **MSK ← ECS**: 允许ECS访问Kafka端口

## 监控和日志

### CloudWatch日志组
- `/ecs/clickstream-alb-cluster`: ECS容器日志
- 按容器和任务分组的日志流

### 监控指标
- **ALB**: 请求数、响应时间、错误率
- **ECS**: CPU、内存使用率、任务健康状态
- **Vector**: 数据处理量、错误计数

## 故障排除

### 常见问题检查清单

1. **Docker镜像**
   - [ ] ECR仓库存在
   - [ ] 镜像推送成功
   - [ ] 镜像标签正确

2. **ECS服务**
   - [ ] 任务定义注册成功
   - [ ] 服务运行正常
   - [ ] 容器健康检查通过

3. **ALB配置**
   - [ ] 目标组健康检查通过
   - [ ] 监听器配置正确
   - [ ] DNS解析正常

4. **网络连通性**
   - [ ] 安全组规则配置正确
   - [ ] 子网路由表配置
   - [ ] NAT网关正常工作

5. **数据流测试**
   - [ ] ALB健康检查端点可访问
   - [ ] 数据收集端点响应正常
   - [ ] MSK接收到数据

### 调试命令

```bash
# 检查ECS服务状态
aws ecs describe-services --cluster clickstream-alb-cluster --services clickstream-alb-optimized-service

# 检查ALB目标健康状态
aws elbv2 describe-target-health --target-group-arn <TARGET_GROUP_ARN>

# 查看容器日志
aws logs tail /ecs/clickstream-alb-cluster --follow

# 测试健康检查
curl http://<ALB_DNS>:8802/health

# 运行数据流测试
./test-data-flow.sh --count 5
```

## 性能调优

### 资源配置建议

| 负载级别 | ECS任务数 | CPU | 内存 | EBS大小 |
|----------|-----------|-----|------|---------|
| 轻量级 | 2 | 4096 | 8192 | 200GB |
| 中等负载 | 4 | 8192 | 16384 | 500GB |
| 高负载 | 8+ | 16384 | 32768 | 1000GB+ |

### Vector配置优化
- 调整批处理大小和超时
- 配置合适的缓冲区大小
- 优化线程数量设置

## 成本优化

### 建议措施
1. **按需调整**: 根据实际负载调整ECS任务数量
2. **预留实例**: 对稳定负载使用预留实例
3. **存储优化**: 合理设置EBS卷大小和类型
4. **日志管理**: 设置CloudWatch日志保留期

## 安全最佳实践

### 网络安全
- 使用私有子网部署ECS服务
- 最小化安全组规则
- 启用VPC Flow Logs

### 数据安全
- 启用传输加密
- 配置IAM最小权限
- 定期轮换访问密钥

## 扩展和定制

### 自定义配置
- 修改Nginx配置文件
- 调整Vector数据处理逻辑
- 添加自定义监控指标

### 集成其他服务
- 添加WAF保护
- 集成API Gateway
- 连接其他数据源

## 文档索引

- **主文档**: `README.md` - 完整使用指南
- **Docker构建**: `docker/README.md` - 镜像构建详细说明
- **ECS部署**: `ecs/README.md` - ECS服务部署指南
- **ALB部署**: `alb/README.md` - 负载均衡器配置
- **项目结构**: `PROJECT_STRUCTURE.md` - 本文档

每个组件都有独立的README文档，提供详细的配置参数和使用说明。

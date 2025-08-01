# NLB部署脚本使用说明

## 概述

`deploy-nlb-optimized.sh` 是一个优化的脚本，用于创建网络负载均衡器(NLB)并与ECS服务绑定。

## 主要特性

1. **参数化配置**: 支持通过命令行参数指定区域、VPC、集群名称和服务名称
2. **智能子网选择**: 自动获取ECS服务所在VPC的公有子网，确保NLB能够提供internet-facing服务
3. **可用区匹配**: 自动选择与ECS服务相同可用区的公有子网，确保最佳网络性能
4. **跨AZ负载均衡**: 自动启用跨可用区负载均衡
5. **资源存在性检查**: 创建前检查资源是否已存在，避免重复创建
6. **强制重建选项**: 支持删除并重新创建现有资源
7. **详细的帮助文档**: 提供完整的使用说明

## 网络架构说明

脚本会自动处理以下网络配置：

- **ECS服务**: 通常运行在私有子网中，确保安全性
- **NLB**: 部署在公有子网中，提供internet-facing访问
- **可用区匹配**: NLB选择与ECS服务相同可用区的公有子网，减少跨AZ流量成本
- **自动发现**: 通过路由表检查自动识别公有子网（包含指向IGW的路由）

## 使用方法

### 基本用法

```bash
# 使用默认参数
./deploy-nlb-optimized.sh

# 指定自定义参数
./deploy-nlb-optimized.sh --region us-west-2 --cluster my-cluster --service my-service

# 强制重建所有资源
./deploy-nlb-optimized.sh --force
```

### 参数说明

| 参数 | 短参数 | 说明 | 默认值 |
|------|--------|------|--------|
| `--region` | `-r` | AWS区域 | `us-east-1` |
| `--vpc` | `-v` | VPC ID | 自动从ECS服务获取 |
| `--cluster` | `-c` | ECS集群名称 | `clickstream-cluster` |
| `--service` | `-s` | ECS服务名称 | `clickstream-optimized-service` |
| `--force` | `-f` | 强制删除并重新创建资源 | `false` |
| `--help` | `-h` | 显示帮助信息 | - |

### 使用示例

```bash
# 1. 查看帮助信息
./deploy-nlb-optimized.sh --help

# 2. 在不同区域部署
./deploy-nlb-optimized.sh --region us-west-2

# 3. 为特定的ECS集群和服务创建NLB
./deploy-nlb-optimized.sh \
  --region us-east-1 \
  --cluster production-cluster \
  --service web-service

# 4. 强制重建现有资源
./deploy-nlb-optimized.sh \
  --cluster my-cluster \
  --service my-service \
  --force

# 5. 使用短参数
./deploy-nlb-optimized.sh -r us-west-2 -c my-cluster -s my-service -f
```

## 脚本执行流程

1. **参数解析和验证**: 解析命令行参数并验证必要参数
2. **ECS服务信息获取**: 
   - 获取ECS服务的VPC、私有子网、容器端口等信息
   - 确定ECS服务所在的可用区
3. **公有子网发现**:
   - 扫描VPC中的所有子网
   - 通过路由表检查识别公有子网（包含IGW路由）
   - 筛选出与ECS服务相同可用区的公有子网
4. **资源存在性检查**: 检查目标组和NLB是否已存在
5. **资源创建/更新**:
   - 创建目标组（如果不存在）
   - 在公有子网中创建网络负载均衡器（如果不存在）
   - 创建监听器
   - 启用跨AZ负载均衡
   - 将ECS服务与目标组关联
6. **信息保存**: 将部署信息保存到 `nlb-info.txt` 文件

## 输出文件

脚本执行完成后会生成 `nlb-info.txt` 文件，包含以下信息：

- 部署时间
- 配置参数
- 资源ARN和名称
- 访问URL
- ECS服务子网（私有）
- NLB子网（公有）
- 可用区信息

## 网络要求

1. **VPC配置**: 
   - VPC必须同时包含私有子网和公有子网
   - 公有子网必须有指向互联网网关(IGW)的路由
   - 私有子网和公有子网应该在相同的可用区中

2. **ECS服务配置**:
   - ECS服务通常部署在私有子网中
   - 确保安全组允许从NLB到ECS任务的流量

3. **安全组配置**:
   - NLB会自动处理安全组，但确保ECS任务的安全组允许来自NLB的流量

## 注意事项

1. **权限要求**: 确保AWS CLI已配置，且具有创建和管理ELB、ECS、EC2资源的权限
2. **ECS服务状态**: 确保目标ECS服务正在运行且配置正确
3. **网络配置**: 脚本会自动选择公有子网，确保VPC中存在与ECS服务相同可用区的公有子网
4. **端口配置**: 脚本会自动检测容器端口，如果检测失败会使用默认端口8802
5. **成本优化**: 通过选择相同可用区的子网，减少跨AZ数据传输成本

## 故障排除

如果脚本执行失败，请检查：

1. **AWS CLI配置**: 是否正确配置且有足够权限
2. **ECS服务**: 指定的ECS集群和服务是否存在
3. **网络配置**: 
   - VPC中是否存在公有子网
   - 公有子网是否与ECS服务在相同可用区
   - 公有子网的路由表是否包含IGW路由
4. **资源限制**: 是否达到了AWS资源限制

### 常见错误

- **"在ECS服务所在的可用区中未找到公有子网"**: 确保VPC中存在与ECS服务相同可用区的公有子网
- **"无法获取VPC ID"**: 检查ECS服务是否正确配置了网络
- **权限错误**: 确保IAM角色/用户有足够的权限创建ELB和EC2资源


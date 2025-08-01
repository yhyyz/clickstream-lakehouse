#!/bin/bash

# 获取容器IP地址
CONTAINER_IP=$(hostname -i | awk '{print $1}')

# 替换nginx配置文件中的CONTAINER_IP占位符
sed -i "s/CONTAINER_IP/$CONTAINER_IP/g" /opt/app/collect-app/conf/nginx.conf

# 启动nginx
/usr/local/openresty/bin/openresty -p /opt/app/collect-app/ -c conf/nginx.conf


# 定期输出错误日志的函数
monitor_logs() {
    while true; do
        sleep 60  # 等待1分钟 (60秒)
        echo "=== $(date) - Nginx Error Logs (Last 10 lines) ==="
        # 查找最新的nginx_error开头的文件并输出最后10行
        latest_error_log=$(ls -t /opt/app/collect-app/logs/nginx_error* 2>/dev/null | head -1)
        if [ -n "$latest_error_log" ]; then
            tail -10 "$latest_error_log"
        else
            echo "No nginx_error log files found"
        fi
        echo "wait 60s, tail -10 nginx_eorr log"
    done
}

# 在后台启动日志监控
monitor_logs

FROM openresty/openresty:1.25.3.2-5-alpine-fat

# 安装必要的工具
RUN apk add --no-cache curl wget unzip

# 创建应用目录结构
RUN mkdir -p /opt/app/collect-app/logs/ \
    && mkdir -p /opt/app/collect-app/conf/vhost/ \
    && mkdir -p /opt/app/collect-app/lua/

# 复制mime.types文件
RUN cp /usr/local/openresty/nginx/conf/mime.types /opt/app/collect-app/conf/

# 下载并安装lua-resty-kafka
WORKDIR /opt/app/collect-app/
RUN wget https://github.com/doujiang24/lua-resty-kafka/archive/master.zip \
    && unzip master.zip \
    && rm master.zip

# 复制配置文件
COPY nginx.conf /opt/app/collect-app/conf/nginx.conf
COPY collect-app.conf /opt/app/collect-app/conf/vhost/collect-app.conf
COPY collect-app.lua /opt/app/collect-app/lua/collect-app.lua
COPY start.sh /opt/app/collect-app/start.sh

# 设置执行权限
RUN chmod +x /opt/app/collect-app/start.sh

# 暴露端口
EXPOSE 8802

# 设置工作目录
WORKDIR /opt/app/collect-app

# 启动脚本
CMD ["/opt/app/collect-app/start.sh"]

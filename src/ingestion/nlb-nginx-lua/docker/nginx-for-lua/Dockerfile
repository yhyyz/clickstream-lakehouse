FROM openresty/openresty:1.25.3.2-5-alpine-fat AS builder

# 安装构建依赖
RUN apk add --no-cache cmake make gcc g++ wget unzip zlib-dev

# 下载并编译 lua-zlib
WORKDIR /tmp
RUN wget https://github.com/brimworks/lua-zlib/archive/master.zip \
    && unzip master.zip \
    && rm master.zip \
    && cd lua-zlib-master \
    && cmake -DLUA_INCLUDE_DIR=/usr/local/openresty/luajit/include/luajit-2.1 -DLUA_LIBRARIES=/usr/local/openresty/luajit/lib/libluajit-5.1.so -DLUA_EXECUTABLE=/usr/local/openresty/luajit/bin/luajit  \
    && make
    

# 第二阶段：最终镜像
FROM openresty/openresty:1.25.3.2-5-alpine-fat

# 安装必要的工具（不包括cmake）
RUN apk add --no-cache curl wget unzip

# 创建应用目录结构
RUN mkdir -p /opt/app/collect-app/logs/ \
    && mkdir -p /opt/app/collect-app/conf/vhost/ \
    && mkdir -p /opt/app/collect-app/lua/

# 复制mime.types文件
RUN cp /usr/local/openresty/nginx/conf/mime.types /opt/app/collect-app/conf/

# 从构建阶段复制编译好的 zlib.so
COPY --from=builder /tmp/lua-zlib-master/zlib.so /usr/local/openresty/lualib/zlib.so

# 下载并安装lua-resty-kafka
WORKDIR /opt/app/collect-app/
RUN wget https://github.com/doujiang24/lua-resty-kafka/archive/master.zip \
    && unzip master.zip \
    && rm master.zip

# 复制配置文件
COPY nginx.conf /opt/app/collect-app/conf/nginx.conf
COPY collect-app.conf /opt/app/collect-app/conf/vhost/collect-app.conf
COPY collect-app.lua /opt/app/collect-app/lua/collect-app.lua
COPY kafka-health.lua /opt/app/collect-app/lua/kafka-health.lua
COPY start.sh /opt/app/collect-app/start.sh

# 设置执行权限
RUN chmod +x /opt/app/collect-app/start.sh

# 暴露端口
EXPOSE 8802

# 设置工作目录
WORKDIR /opt/app/collect-app

# 启动脚本
CMD ["/opt/app/collect-app/start.sh"]

FROM jenkins/jenkins:lts-jdk21

USER root

# Jenkins 只负责从 SCM 拉取并打包源码；Docker 构建在生产服务器执行。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        gzip \
        tar \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER jenkins

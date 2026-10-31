FROM maven:3.9-eclipse-temurin-25 AS builder

WORKDIR /workspace

# 生产服务器与既有容器共享内存，限制 Maven 峰值，避免远程构建挤压在线服务。
ENV MAVEN_OPTS="-Xms128m -Xmx768m -XX:+UseSerialGC"

COPY pom.xml ./
RUN --mount=type=cache,id=trade-tool-maven-repository,target=/root/.m2,sharing=locked \
    mvn -B -DskipTests dependency:go-offline

COPY src ./src
RUN --mount=type=cache,id=trade-tool-maven-repository,target=/root/.m2,sharing=locked \
    mvn -B package

FROM eclipse-temurin:25-jre

WORKDIR /app

RUN useradd --system --uid 10001 --create-home appuser

COPY --from=builder --chown=appuser:appuser /workspace/target/app-service-*.jar /app/app.jar

USER appuser

ENTRYPOINT ["java", "-jar", "/app/app.jar"]

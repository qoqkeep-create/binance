pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        skipDefaultCheckout(true)
        timeout(time: 180, unit: 'MINUTES')
    }

    parameters {
        string(name: 'DEPLOY_SERVER_HOST', defaultValue: '192.168.100.100', description: '生产服务器 IP 或域名。')
        string(name: 'DEPLOY_SERVER_PORT', defaultValue: '22', description: '生产服务器 SSH 端口。')
        string(name: 'SSH_CREDENTIALS_ID', defaultValue: 'ssh-home', description: 'Jenkins 中保存的服务器用户名/密码凭据ID。')
        string(name: 'PRODUCTION_ENV_CREDENTIALS_ID', defaultValue: 'trade-tool-production-env', description: 'Jenkins 中保存的生产环境 Secret file 凭据 ID。')
        string(name: 'REMOTE_WORK_DIR', defaultValue: '/tmp/trade-tool-jenkins-workspace', description: '上传源码及远程构建使用的临时目录。')
        string(name: 'APP_DEPLOY_DIR', defaultValue: '/opt/trade-tool', description: 'Compose、生产环境文件和日志的持久化目录。')
        string(name: 'APP_PORT_MAPPING', defaultValue: '127.0.0.1:8686:8686', description: 'API 端口映射；仅供宿主机 Nginx 反向代理访问。')
        string(name: 'APP_IMAGE', defaultValue: 'trade-tool-app', description: '生产服务器本地应用镜像名称。')
        booleanParam(name: 'PULL_BASE_IMAGES', defaultValue: false, description: '是否主动重新拉取 Compose 固定的基础镜像；镜像缺失时无论此项是否勾选都会自动拉取。')
        booleanParam(name: 'FORCE_FULL_DEPLOY', defaultValue: false, description: '忽略文件变更范围，强制执行完整生产部署。')
    }

    environment {
        COMPOSE_PROJECT_NAME = 'trade-tool'
        SOURCE_ARCHIVE = 'trade-tool-source.tar.gz'
        LOCAL_PRODUCTION_ENV = '.jenkins-production.env'
        REMOTE_SOURCE_DIR_NAME = 'source'
        DEPLOY_SCOPE = 'FULL'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHORT = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()
                    env.RELEASE_ID = "${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    env.APP_TAG = env.RELEASE_ID
                }
            }
        }

        stage('Determine Deployment Scope') {
            steps {
                script {
                    def changedFiles = deploymentChangedFiles()
                    env.DEPLOY_SCOPE = deploymentScopeFor(
                        changedFiles,
                        params.FORCE_FULL_DEPLOY == true
                    )

                    echo "变更文件（${changedFiles.size()} 个）：\n${changedFiles.collect { "- ${it}" }.join('\n')}"
                    echo "本次部署范围：${deploymentScopeDescription(env.DEPLOY_SCOPE)}"

                    if (env.DEPLOY_SCOPE == 'SKIP') {
                        currentBuild.description = "无需部署 | ${env.RELEASE_ID}"
                    }
                }
            }
        }

        stage('Validate Parameters') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    validateDeploymentParameters()
                    env.DEPLOY_PARAMETERS_VALIDATED = 'true'
                    env.API_SMOKE_HOST = smokeHostFromPortMapping(
                        params.APP_PORT_MAPPING
                    )
                    env.API_SMOKE_PORT = serverPortFromMapping(
                        params.APP_PORT_MAPPING
                    )
                    currentBuild.description = "${params.DEPLOY_SERVER_HOST.trim()} | ${env.DEPLOY_SCOPE} | ${env.RELEASE_ID}"

                    echo "部署服务器：${params.DEPLOY_SERVER_HOST.trim()}:${params.DEPLOY_SERVER_PORT.trim()}"
                    echo "远程构建目录：${params.REMOTE_WORK_DIR.trim()}"
                    echo "应用运行目录：${params.APP_DEPLOY_DIR.trim()}"
                    echo "API 端口映射：${params.APP_PORT_MAPPING.trim()}"
                    echo "应用镜像：${params.APP_IMAGE.trim()}:${env.APP_TAG}"
                    echo "部署范围：${deploymentScopeDescription(env.DEPLOY_SCOPE)}"
                }
            }
        }

        stage('Package Source') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                sh '''
                    set -eu
                    rm -f "$SOURCE_ARCHIVE"

                    tar -czf "$SOURCE_ARCHIVE" \
                        --exclude='backend/app-service/target' \
                        --exclude='backend/app-service/logs' \
                        --exclude='.DS_Store' \
                        Jenkinsfile \
                        README.md \
                        compose.remote.yaml \
                        deploy/nginx/trade-tool.conf.example \
                        deploy/nginx/sync-certificate.sh \
                        deploy/validate-production-env.sh \
                        backend/app-service

                    test -s "$SOURCE_ARCHIVE"
                    ls -lh "$SOURCE_ARCHIVE"
                '''
            }
        }

        stage('Check Remote Server') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    withDeployRemote { remote ->
                        sshCommand remote: remote, command: """
                            set -eu

                            for command_name in docker tar curl install nginx; do
                                if ! command -v \"\${command_name}\" >/dev/null 2>&1; then
                                    echo \"生产服务器缺少 \${command_name}，请先安装。\" >&2
                                    exit 1
                                fi
                            done

                            if ! docker compose version >/dev/null 2>&1; then
                                echo '生产服务器缺少 Docker Compose v2。' >&2
                                exit 1
                            fi
                            if ! systemctl is-active --quiet nginx; then
                                echo '宿主机 Nginx 未运行，拒绝发布没有 HTTPS 入口的生产服务。' >&2
                                exit 1
                            fi
                            nginx -t

                            install -d -m 700 '${params.REMOTE_WORK_DIR.trim()}'
                            install -d -m 750 '${params.APP_DEPLOY_DIR.trim()}'
                            install -d -m 750 '${params.APP_DEPLOY_DIR.trim()}/logs'
                            install -d -m 750 '${params.APP_DEPLOY_DIR.trim()}/mysql/data'
                            install -d -m 750 '${params.APP_DEPLOY_DIR.trim()}/redis/data'
                            install -d -m 750 '${params.APP_DEPLOY_DIR.trim()}/nginx'
                            install -d -m 700 '${params.APP_DEPLOY_DIR.trim()}/nginx/ssl'

                            total_memory_mb=\$((\$(awk '/MemTotal:/ {print \$2}' /proc/meminfo) / 1024))
                            if [ \"\${total_memory_mb}\" -lt 4096 ]; then
                                echo \"警告：服务器总内存仅 \${total_memory_mb} MB；已有其他容器时，生产部署前建议扩容。\" >&2
                            fi
                            if [ \"\$(awk '/SwapTotal:/ {print \$2}' /proc/meminfo)\" -eq 0 ]; then
                                echo '警告：服务器没有 Swap；Compose 已限制新容器内存，但远程镜像构建仍需关注 OOM。' >&2
                            fi
                        """
                    }
                }
            }
        }

        stage('Upload Source & Configuration') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    if (env.DEPLOY_SCOPE == 'FULL') {
                        withCredentials([file(
                            credentialsId: params.PRODUCTION_ENV_CREDENTIALS_ID.trim(),
                            variable: 'PRODUCTION_ENV_FILE'
                        )]) {
                            sh '''
                                set -eu
                                install -m 600 "$PRODUCTION_ENV_FILE" "$LOCAL_PRODUCTION_ENV"
                            '''
                        }
                    }

                    withDeployRemote { remote ->
                        sshPut remote: remote,
                            from: env.SOURCE_ARCHIVE,
                            into: "${params.REMOTE_WORK_DIR.trim()}/"
                        if (env.DEPLOY_SCOPE == 'FULL') {
                            sshPut remote: remote,
                                from: env.LOCAL_PRODUCTION_ENV,
                                into: "${params.REMOTE_WORK_DIR.trim()}/"
                        }

                        sshCommand remote: remote, command: """
                                set -eu

                                work_dir='${params.REMOTE_WORK_DIR.trim()}'
                                source_dir=\"\${work_dir}/${env.REMOTE_SOURCE_DIR_NAME}\"
                                uploaded_env=\"\${work_dir}/${env.LOCAL_PRODUCTION_ENV}\"
                                candidate_env='${params.APP_DEPLOY_DIR.trim()}/.env.production.candidate'
                                current_env='${params.APP_DEPLOY_DIR.trim()}/.env.production'
                                current_compose='${params.APP_DEPLOY_DIR.trim()}/compose.yaml'
                                compose_file=\"\${source_dir}/compose.remote.yaml\"

                                rm -rf \"\${source_dir}\"
                                install -d -m 750 \"\${source_dir}\"
                                tar -xzf \"\${work_dir}/${env.SOURCE_ARCHIVE}\" -C \"\${source_dir}\"
                                rm -f \"\${work_dir}/${env.SOURCE_ARCHIVE}\"

                                if [ '${env.DEPLOY_SCOPE}' = 'FULL' ]; then
                                    install -m 600 \"\${uploaded_env}\" \"\${candidate_env}\"
                                    install -m 640 \\
                                        \"\${source_dir}/deploy/nginx/trade-tool.conf.example\" \\
                                        '${params.APP_DEPLOY_DIR.trim()}/nginx/trade-tool.conf.example'
                                    install -m 750 \\
                                        \"\${source_dir}/deploy/nginx/sync-certificate.sh\" \\
                                        '${params.APP_DEPLOY_DIR.trim()}/nginx/sync-certificate.sh'
                                else
                                    if [ ! -s \"\${current_env}\" ] || [ ! -s \"\${current_compose}\" ]; then
                                        echo '服务器缺少现有生产环境或 Compose 文件，请执行完整部署。' >&2
                                        exit 1
                                    fi
                                    awk -F= '
                                        \$1 != \"COMPOSE_PROJECT_NAME\" &&
                                        \$1 != \"APP_IMAGE\" &&
                                        \$1 != \"APP_TAG\" &&
                                        \$1 != \"APP_PORT_MAPPING\" &&
                                        \$1 != \"LOG_DIR\" &&
                                        \$1 != \"LOG_FILE\" { print }
                                    ' \"\${current_env}\" > \"\${candidate_env}\"
                                    compose_file=\"\${current_compose}\"
                                fi
                                rm -f \"\${uploaded_env}\"

                                printf '\\n%s\\n' \\
                                    'COMPOSE_PROJECT_NAME=${env.COMPOSE_PROJECT_NAME}' \\
                                    'APP_IMAGE=${params.APP_IMAGE.trim()}' \\
                                    'APP_TAG=${env.APP_TAG}' \\
                                    'APP_PORT_MAPPING=${params.APP_PORT_MAPPING.trim()}' \\
                                    'INFRA_BIND_HOST=127.0.0.1' \\
                                    'MYSQL_DATA_DIR=${params.APP_DEPLOY_DIR.trim()}/mysql/data' \\
                                    'REDIS_DATA_DIR=${params.APP_DEPLOY_DIR.trim()}/redis/data' \\
                                    'LOG_DIR=${params.APP_DEPLOY_DIR.trim()}/logs' \\
                                    'LOG_FILE=/app/logs/trade-tool.log' \\
                                    >> \"\${candidate_env}\"

                                chmod 600 \"\${candidate_env}\"
                                \"\${source_dir}/deploy/validate-production-env.sh\" \"\${candidate_env}\"
                                docker compose \\
                                    --env-file \"\${candidate_env}\" \\
                                    -f \"\${compose_file}\" \\
                                    config --quiet
                        """
                    }
                }
            }
        }

        stage('Build Application Image') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    def pullFlag = params.PULL_BASE_IMAGES ? '--pull' : ''
                    withDeployRemote { remote ->
                        sshCommand remote: remote, command: """
                            set -eu

                            source_dir='${params.REMOTE_WORK_DIR.trim()}/${env.REMOTE_SOURCE_DIR_NAME}'
                            image='${params.APP_IMAGE.trim()}:${env.APP_TAG}'
                            build_attempt=1

                            while true; do
                                if DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build \\
                                    ${pullFlag} \\
                                    --tag \"\${image}\" \\
                                    --file \"\${source_dir}/backend/app-service/Dockerfile\" \\
                                    \"\${source_dir}/backend/app-service\"; then
                                    break
                                fi

                                if [ \"\${build_attempt}\" -ge 2 ]; then
                                    echo '应用镜像连续构建失败 2 次，终止生产部署。' >&2
                                    exit 1
                                fi

                                build_attempt=\$((build_attempt + 1))
                                echo '镜像构建失败，10 秒后自动重试；已完成的 Docker 层继续复用。'
                                sleep 10
                            done

                            runtime_uid=\$(docker run --rm --entrypoint id \"\${image}\" -u)
                            runtime_gid=\$(docker run --rm --entrypoint id \"\${image}\" -g)
                            chown -R \"\${runtime_uid}:\${runtime_gid}\" '${params.APP_DEPLOY_DIR.trim()}/logs'
                            chmod 750 '${params.APP_DEPLOY_DIR.trim()}/logs'
                        """
                    }
                }
            }
        }

        stage('Deploy Production') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    def deployTargetArgs = env.DEPLOY_SCOPE == 'BACKEND'
                        ? '--no-deps trade_app'
                        : ''
                    def pullInfrastructure = env.DEPLOY_SCOPE == 'FULL'
                        ? params.PULL_BASE_IMAGES
                        : false
                    withDeployRemote { remote ->
                        sshCommand remote: remote, command: """
                            set -eu

                            app_dir='${params.APP_DEPLOY_DIR.trim()}'
                            source_dir='${params.REMOTE_WORK_DIR.trim()}/${env.REMOTE_SOURCE_DIR_NAME}'
                            current_env=\"\${app_dir}/.env.production\"
                            previous_env=\"\${app_dir}/.env.production.previous\"
                            candidate_env=\"\${app_dir}/.env.production.candidate\"
                            current_compose=\"\${app_dir}/compose.yaml\"
                            previous_compose=\"\${app_dir}/compose.yaml.previous\"

                            if [ -f \"\${current_env}\" ]; then
                                cp -p \"\${current_env}\" \"\${previous_env}\"
                            else
                                rm -f \"\${previous_env}\"
                            fi
                            if [ -f \"\${current_compose}\" ]; then
                                cp -p \"\${current_compose}\" \"\${previous_compose}\"
                            else
                                rm -f \"\${previous_compose}\"
                            fi

                            install -m 600 \"\${candidate_env}\" \"\${current_env}\"
                            if [ '${env.DEPLOY_SCOPE}' = 'FULL' ]; then
                                install -m 640 \"\${source_dir}/compose.remote.yaml\" \"\${current_compose}\"
                            fi
                            rm -f \"\${candidate_env}\"

                            if [ '${pullInfrastructure}' = 'true' ]; then
                                docker compose \\
                                    --env-file \"\${current_env}\" \\
                                    -f \"\${current_compose}\" \\
                                    pull trade_mysql trade_redis
                            fi

                            if ! docker compose \\
                                --env-file \"\${current_env}\" \\
                                -f \"\${current_compose}\" \\
                                up -d \\
                                --no-build \\
                                --pull missing \\
                                --remove-orphans \\
                                --wait \\
                                --wait-timeout 600 \\
                                ${deployTargetArgs}; then
                                echo '生产容器启动失败，输出诊断信息并尝试回滚。' >&2
                                docker compose \\
                                    --env-file \"\${current_env}\" \\
                                    -f \"\${current_compose}\" \\
                                    ps || true
                                docker compose \\
                                    --env-file \"\${current_env}\" \\
                                    -f \"\${current_compose}\" \\
                                    logs --no-color --tail 300 trade_app || true

                                if [ -f \"\${previous_env}\" ] && [ -f \"\${previous_compose}\" ]; then
                                    cp -p \"\${previous_env}\" \"\${current_env}\"
                                    cp -p \"\${previous_compose}\" \"\${current_compose}\"
                                    docker compose \\
                                        --env-file \"\${current_env}\" \\
                                        -f \"\${current_compose}\" \\
                                        up -d \\
                                        --no-build \\
                                        --pull never \\
                                        --remove-orphans \\
                                        ${deployTargetArgs} || true
                                else
                                    echo '首次部署没有上一版本可回滚。' >&2
                                fi
                                exit 1
                            fi
                        """
                    }
                }
            }
        }

        stage('Smoke Test') {
            when {
                expression { env.DEPLOY_SCOPE != 'SKIP' }
            }
            steps {
                script {
                    try {
                        withDeployRemote { remote ->
                            sshCommand remote: remote, command: """
                                set -eu

                                attempt=1
                                while [ \"\${attempt}\" -le 36 ]; do
                                    http_status=\$(curl \\
                                        --silent \\
                                        --show-error \\
                                        --output /dev/null \\
                                        --write-out '%{http_code}' \\
                                        --max-time 10 \\
                                        'http://${env.API_SMOKE_HOST}:${env.API_SMOKE_PORT}/api/auth/me' || true)

                                    if [ \"\${http_status}\" = '200' ] || [ \"\${http_status}\" = '401' ]; then
                                        echo \"API 冒烟检查通过，HTTP \${http_status}。\"
                                        printf '%s\\n' '${env.RELEASE_ID}' > '${params.APP_DEPLOY_DIR.trim()}/.image-tag'
                                        docker compose \\
                                            --env-file '${params.APP_DEPLOY_DIR.trim()}/.env.production' \\
                                            -f '${params.APP_DEPLOY_DIR.trim()}/compose.yaml' \\
                                            ps
                                        docker compose \\
                                            --env-file '${params.APP_DEPLOY_DIR.trim()}/.env.production' \\
                                            -f '${params.APP_DEPLOY_DIR.trim()}/compose.yaml' \\
                                            logs --no-color --tail 120 trade_app
                                        exit 0
                                    fi

                                    echo \"API 尚未就绪，HTTP \${http_status:-000}，5 秒后重试（\${attempt}/36）。\"
                                    attempt=\$((attempt + 1))
                                    sleep 5
                                done

                                echo 'API 冒烟检查超时。' >&2
                                exit 1
                            """
                        }
                    } catch (Exception smokeError) {
                        echo '新版本冒烟检查失败，开始恢复上一版本。'
                        try {
                            withDeployRemote { remote ->
                                rollbackRemoteDeployment(remote, env.DEPLOY_SCOPE)
                            }
                        } catch (Exception rollbackError) {
                            echo "自动回滚未完成：${rollbackError.message}"
                        }
                        throw smokeError
                    }
                }
            }
        }
    }

    post {
        always {
            sh '''
                rm -f "$SOURCE_ARCHIVE" "$LOCAL_PRODUCTION_ENV"
            '''
            script {
                try {
                    if (env.DEPLOY_PARAMETERS_VALIDATED == 'true') {
                        withDeployRemote { remote ->
                            sshCommand remote: remote, command: """
                                rm -f \\
                                    '${params.REMOTE_WORK_DIR.trim()}/${env.SOURCE_ARCHIVE}' \\
                                    '${params.REMOTE_WORK_DIR.trim()}/${env.LOCAL_PRODUCTION_ENV}' \\
                                    '${params.APP_DEPLOY_DIR.trim()}/.env.production.candidate'
                            """
                        }
                    }
                } catch (Exception cleanupError) {
                    echo "远程临时文件清理失败：${cleanupError.message}"
                }
            }
        }
        success {
            script {
                if (env.DEPLOY_SCOPE == 'SKIP') {
                    echo "本次仅包含 iOS APP 或文档变更，未连接生产服务器，跳过生产部署。"
                } else {
                    withDeployRemote { remote ->
                        removeOldApplicationImages(remote)
                    }
                    echo "生产发布 ${env.RELEASE_ID} 完成，范围：${deploymentScopeDescription(env.DEPLOY_SCOPE)}。"
                }
            }
        }
        failure {
            echo "生产发布 ${env.RELEASE_ID ?: env.BUILD_NUMBER} 失败，请检查构建日志和服务器诊断输出。"
        }
    }
}

def deploymentChangedFiles() {
    def currentCommit = sh(
        script: 'git rev-parse HEAD',
        returnStdout: true
    ).trim()
    def baseCommit = null

    for (String candidate : [
        env.GIT_PREVIOUS_SUCCESSFUL_COMMIT,
        env.GIT_PREVIOUS_COMMIT
    ]) {
        def normalized = candidate?.trim()
        if (normalized
                && normalized != currentCommit
                && (normalized ==~ /^[0-9a-fA-F]{7,40}$/)
                && sh(
                    script: "git cat-file -e '${normalized}^{commit}'",
                    returnStatus: true
                ) == 0) {
            baseCommit = normalized
            break
        }
    }

    if (!baseCommit) {
        echo '无法确定可靠的上次部署提交，本次按完整部署处理。'
        return ['Jenkinsfile']
    }

    def output = sh(
        script: "git diff --name-only --diff-filter=ACDMRTUXB '${baseCommit}' '${currentCommit}'",
        returnStdout: true
    ).trim()
    if (!output) {
        echo '提交差异为空，本次按手动重部署处理。'
        return ['Jenkinsfile']
    }

    return output.readLines()
        .collect { it.trim() }
        .findAll { it }
        .unique()
        .sort()
}

def deploymentScopeFor(List<String> changedFiles, boolean forceFullDeploy) {
    if (forceFullDeploy) {
        return 'FULL'
    }

    for (String path : changedFiles) {
        if (path == 'Jenkinsfile'
                || path == 'compose.yaml'
                || (path.startsWith('compose.') && path.endsWith('.yaml'))
                || path == '.env.example'
                || path == 'backend/app-service/Dockerfile'
                || path == 'backend/app-service/.dockerignore'
                || path.startsWith('deploy/')) {
            return 'FULL'
        }
    }

    for (String path : changedFiles) {
        if (path.startsWith('backend/app-service/')) {
            return 'BACKEND'
        }
    }

    for (String path : changedFiles) {
        if (!(path.startsWith('frontend/ios-app/')
                || path.startsWith('docs/')
                || path == 'README.md'
                || path == 'AGENTS.md'
                || path == '.gitignore')) {
            return 'FULL'
        }
    }

    return 'SKIP'
}

def deploymentScopeDescription(String scope) {
    switch (scope) {
        case 'FULL':
            return '完整部署（Compose 全部服务）'
        case 'BACKEND':
            return '仅后端（trade_app）'
        case 'SKIP':
            return '跳过部署（仅 iOS APP 或文档变更）'
        default:
            error("未知部署范围：${scope}")
    }
}

def validateDeploymentParameters() {
    validateShellToken('DEPLOY_SERVER_HOST', params.DEPLOY_SERVER_HOST)
    validatePort('DEPLOY_SERVER_PORT', params.DEPLOY_SERVER_PORT)
    validateShellToken('SSH_CREDENTIALS_ID', params.SSH_CREDENTIALS_ID)
    validateShellToken(
        'PRODUCTION_ENV_CREDENTIALS_ID',
        params.PRODUCTION_ENV_CREDENTIALS_ID
    )
    validateSafeAbsolutePath('REMOTE_WORK_DIR', params.REMOTE_WORK_DIR)
    validateSafeAbsolutePath('APP_DEPLOY_DIR', params.APP_DEPLOY_DIR)
    validatePortMapping('APP_PORT_MAPPING', params.APP_PORT_MAPPING)
    validateImageName('APP_IMAGE', params.APP_IMAGE)

    def containerPort = params.APP_PORT_MAPPING.trim().split(':', -1)[-1]
    if (containerPort != '8686') {
        error('APP_PORT_MAPPING 的容器端口必须是 8686。')
    }
    def mappingParts = params.APP_PORT_MAPPING.trim().split(':', -1)
    if (mappingParts.size() != 3 || mappingParts[0] != '127.0.0.1') {
        error('生产 APP_PORT_MAPPING 必须绑定 127.0.0.1，禁止将登录和交易 API 暴露到公网。')
    }
}

def validateShellToken(String name, String value) {
    if (!(value?.trim() ==~ /^[A-Za-z0-9._:@-]+$/)) {
        error("${name} 不能为空，并且只能包含字母、数字、点、下划线、中划线、冒号或 @，当前值：${value}")
    }
}

def validateImageName(String name, String value) {
    if (!(value?.trim() ==~ /^[A-Za-z0-9._\/-]+$/)) {
        error("${name} 不是安全的 Docker 镜像名称，当前值：${value}")
    }
}

def validateSafeAbsolutePath(String name, String value) {
    def path = value?.trim()
    if (!(path ==~ '^/[A-Za-z0-9._/-]+$')
            || path == '/'
            || path.contains('/../')
            || path.endsWith('/..')) {
        error("${name} 必须是安全的绝对路径，不能是根目录，也不能包含空格、特殊字符或 ..，当前值：${value}")
    }
}

def validatePort(String name, String value) {
    def portValue = value?.trim()
    if (!(portValue ==~ /^[0-9]{1,5}$/)) {
        error("${name} 必须是数字，当前值：${value}")
    }

    int port = portValue as int
    if (port < 1 || port > 65535) {
        error("${name} 必须在 1 到 65535 之间，当前值：${value}")
    }
}

def validateIpv4Address(String name, String value) {
    def address = value?.trim()
    def parts = address?.split('\\.', -1)
    if (parts?.size() != 4
            || parts.any {
                !(it ==~ /^[0-9]{1,3}$/) || (it as int) > 255
            }) {
        error("${name} 必须是有效的 IPv4 地址，当前值：${value}")
    }
}

def validatePortMapping(String name, String value) {
    def mapping = value?.trim()
    def parts = mapping?.split(':', -1)
    if (!(parts?.size() in [2, 3])) {
        error("${name} 必须是 服务器端口:容器端口，或 IP:服务器端口:容器端口，当前值：${value}")
    }

    if (parts.size() == 3) {
        validateIpv4Address("${name} 的监听地址", parts[0])
    }

    validatePort("${name} 的服务器端口", parts[-2])
    validatePort("${name} 的容器端口", parts[-1])
}

def serverPortFromMapping(String mapping) {
    def parts = mapping.trim().split(':', -1)
    return parts[-2]
}

def smokeHostFromPortMapping(String mapping) {
    def parts = mapping.trim().split(':', -1)
    if (parts.size() == 3 && parts[0] != '0.0.0.0') {
        return parts[0]
    }
    return '127.0.0.1'
}

def withDeployRemote(Closure body) {
    withCredentials([usernamePassword(
        credentialsId: params.SSH_CREDENTIALS_ID.trim(),
        usernameVariable: 'DEPLOY_SSH_USER',
        passwordVariable: 'DEPLOY_SSH_PASSWORD'
    )]) {
        def remote = [
            name: 'trade-tool-production-server',
            host: params.DEPLOY_SERVER_HOST.trim(),
            port: params.DEPLOY_SERVER_PORT.trim() as Integer,
            user: env.DEPLOY_SSH_USER,
            password: env.DEPLOY_SSH_PASSWORD,
            allowAnyHosts: true,
            fileTransfer: 'scp',
            timeoutSec: 30,
            retryCount: 2,
            retryWaitSec: 5
        ]
        body(remote)
    }
}

def removeOldApplicationImages(Map remote) {
    sshCommand remote: remote, command: """
        set -eu

        app_image='${params.APP_IMAGE.trim()}'
        current_ref="\${app_image}:${env.APP_TAG}"

        # 冒烟检查成功后才会进入这里。只清理当前应用仓库的旧标签，
        # 不触碰 MySQL、Redis、基础镜像或 BuildKit/Maven 构建缓存。
        docker image inspect "\${current_ref}" >/dev/null
        old_refs=\$(docker image ls \\
            --filter "reference=\${app_image}:*" \\
            --format '{{.Repository}}:{{.Tag}}' | sort -u)
        removed=0

        for image_ref in \${old_refs}; do
            case "\${image_ref}" in
                "\${app_image}:"*) ;;
                *) continue ;;
            esac
            if [ "\${image_ref}" = "\${current_ref}" ]; then
                continue
            fi

            echo "删除旧应用镜像：\${image_ref}"
            docker image rm "\${image_ref}"
            removed=\$((removed + 1))
        done

        # 防止标签清理误伤当前版本；旧的悬空层仍沿用七天保留策略。
        docker image inspect "\${current_ref}" >/dev/null
        docker image prune -f --filter 'until=168h' >/dev/null
        echo "旧应用镜像清理完成，删除 \${removed} 个标签，保留 \${current_ref}。"
    """
}

def rollbackRemoteDeployment(Map remote, String deployScope) {
    def deployTargetArgs = deployScope == 'BACKEND'
        ? '--no-deps trade_app'
        : ''
    sshCommand remote: remote, command: """
        set -eu

        app_dir='${params.APP_DEPLOY_DIR.trim()}'
        current_env=\"\${app_dir}/.env.production\"
        previous_env=\"\${app_dir}/.env.production.previous\"
        current_compose=\"\${app_dir}/compose.yaml\"
        previous_compose=\"\${app_dir}/compose.yaml.previous\"

        if [ ! -f \"\${previous_env}\" ] || [ ! -f \"\${previous_compose}\" ]; then
            echo '首次部署没有上一版本，无法自动回滚。' >&2
            exit 1
        fi

        cp -p \"\${previous_env}\" \"\${current_env}\"
        cp -p \"\${previous_compose}\" \"\${current_compose}\"
        docker compose \\
            --env-file \"\${current_env}\" \\
            -f \"\${current_compose}\" \\
            up -d \\
            --no-build \\
            --pull never \\
            --remove-orphans \\
            --wait \\
            --wait-timeout 600 \\
            ${deployTargetArgs}
        echo '已恢复上一生产版本。'
    """
}

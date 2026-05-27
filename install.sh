#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# 检查ROOT权限
[[ $EUID -ne 0 ]] && echo -e "${red}严重错误：${plain} 请使用 root 权限运行此脚本 \n " && exit 1

# 识别系统版本
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "无法检测系统版本，请联系作者！" >&2
    exit 1
fi
echo "当前系统：$release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}不支持当前CPU架构！ ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "CPU架构：$(arch)"

# 简单判断函数
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# 端口占用检测
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# 安装基础依赖
install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y cronie curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm cronie curl tar tzdata socat ca-certificates openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y cron curl tar timezone socat ca-certificates openssl
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
    esac
}

# 生成随机字符串
gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

# 本地安装PostgreSQL数据库
install_postgres_local() {
    local pg_user="xui"
    local pg_db="xui"
    local pg_pass
    pg_pass=$(gen_random_string 24)

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}当前系统不支持自动安装PostgreSQL：${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    # 等待数据库启动
    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    # 创建账号与数据库（重复执行不报错）
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER ${pg_user} WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE ${pg_db} OWNER ${pg_user};" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER ${pg_user} WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')
    echo "postgres://${pg_user}:${pg_pass_enc}@127.0.0.1:5432/${pg_db}?sslmode=disable"
    return 0
}

# 安装SSL证书工具acme.sh
install_acme() {
    echo -e "${green}正在安装SSL证书管理工具 acme.sh...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}acme.sh 安装失败${plain}"
        return 1
    else
        echo -e "${green}acme.sh 安装成功${plain}"
    fi
    return 0
}

# 为域名配置SSL证书
setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}开始配置SSL证书...${plain}"

    # 检查acme.sh是否存在
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}acme.sh 安装失败，跳过SSL配置${plain}"
            return 1
        fi
    fi

    # 创建证书目录
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # 签发证书
    echo -e "${green}正在为 ${domain} 签发SSL证书...${plain}"
    echo -e "${yellow}注意：服务器80端口必须对外开放并可正常访问${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}为 ${domain} 签发证书失败${plain}"
        echo -e "${yellow}请检查80端口是否开放，稍后可执行 x-ui 重新配置${plain}"
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}证书安装失败${plain}"
        return 1
    fi

    # 开启自动更新与续期
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    # 权限加固：私钥仅管理员可读
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # 绑定证书到面板
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL证书安装并配置完成！${plain}"
        return 0
    else
        echo -e "${yellow}未找到证书文件${plain}"
        return 1
    fi
}

# 为IP地址签发短期SSL证书（有效期约6天）
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2" # 选填

    echo -e "${green}开始为IP地址配置Let's Encrypt短期SSL证书（有效期约6天）${plain}"
    echo -e "${yellow}说明：IP证书有效期约6天，程序会自动续期${plain}"
    echo -e "${yellow}默认使用80端口验证；若修改端口，请确保外网80端口转发至该端口${plain}"

    # 检查acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}acme.sh 安装失败${plain}"
            return 1
        fi
    fi

    # 校验IPv4
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}必须填写IPv4地址${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}IPv4地址格式错误：$ipv4${plain}"
        return 1
    fi

    # 创建证书目录
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # 拼接域名/IP参数
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}已加入IPv6地址：${ipv6}${plain}"
    fi

    # 证书续期后重载命令
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # 选择验证端口
    local WebPort=""
    read -rp "请输入ACME验证使用的端口（默认80）： " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}端口格式错误，将使用默认80端口${plain}"
        WebPort=80
    fi
    echo -e "${green}将使用 ${WebPort} 端口进行验证${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}提醒：Let's Encrypt仅访问外网80端口，请将外网80转发至 ${WebPort}${plain}"
    fi

    # 循环检测端口是否被占用
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}端口 ${WebPort} 已被占用${plain}"

            local alt_port=""
            read -rp "请输入其他端口（留空则终止操作）： " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}端口被占用，无法继续${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}端口格式错误${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}端口 ${WebPort} 空闲，可以开始验证${plain}"
            break
        fi
    done

    # 签发短期IP证书
    echo -e "${green}正在为 ${ipv4} 签发IP证书...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1

    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}IP证书签发失败${plain}"
        echo -e "${yellow}请确认 ${WebPort} 端口外网可访问，或已做好80端口转发${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书签发成功，开始安装...${plain}"

    # 安装证书
    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # 校验证书文件
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}安装后未检测到证书文件${plain}"
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书文件安装完成${plain}"

    # 开启acme.sh自动更新
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    # 权限加固
    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    # 绑定证书到面板
    echo -e "${green}正在将证书配置到面板...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"

    if [ $? -ne 0 ]; then
        echo -e "${yellow}警告：自动配置证书路径失败${plain}"
        echo -e "${yellow}证书文件路径：${plain}"
        echo -e "  证书：${certDir}/fullchain.pem"
        echo -e "  私钥：${certDir}/privkey.pem"
    else
        echo -e "${green}证书路径配置成功${plain}"
    fi

    echo -e "${green}IP证书配置全部完成！${plain}"
    echo -e "${green}证书有效期约6天，会通过定时任务自动续期${plain}"
    echo -e "${yellow}acme.sh 将在证书到期前自动续期并重启面板${plain}"
    return 0
}

# 手动域名证书签发（综合流程）
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # 检查acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未检测到 acme.sh，正在自动安装..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}acme.sh 安装失败${plain}"
            return 1
        else
            echo -e "${green}acme.sh 安装成功${plain}"
        fi
    fi

    # 输入域名
    local domain=""
    while true; do
        read -rp "请输入你的域名： " domain
        domain="${domain// /}"

        if [[ -z "$domain" ]]; then
            echo -e "${red}域名不能为空，请重新输入${plain}"
            continue
        fi

        if ! is_domain "$domain"; then
            echo -e "${red}域名格式错误：${domain}，请输入有效域名${plain}"
            continue
        fi

        break
    done
    echo -e "${green}当前域名：${domain}，开始检测...${plain}"
    SSL_ISSUED_DOMAIN="${domain}"

    # 检测已有证书
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        echo -e "${yellow}检测到该域名已有证书，将直接复用${plain}"
        [[ -n "${certInfo}" ]] && echo "$certInfo"
    else
        echo -e "${green}域名校验通过，准备签发证书${plain}"
    fi

    # 创建证书目录
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # 选择验证端口
    local WebPort=80
    read -rp "请选择验证端口（默认80）： " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}输入端口无效，使用默认80端口${plain}"
        WebPort=80
    fi
    echo -e "${green}将使用 ${WebPort} 端口签发证书，请确保该端口已开放${plain}"

    # 临时停止面板
    echo -e "${yellow}正在临时关闭面板...${plain}"
    systemctl stop x-ui 2> /dev/null || rc-service x-ui stop 2> /dev/null

    # 签发证书
    if [[ ${cert_exists} -eq 0 ]]; then
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            echo -e "${red}证书签发失败，请查看日志排查问题${plain}"
            rm -rf ~/.acme.sh/${domain}
            systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
            return 1
        else
            echo -e "${green}证书签发成功，开始安装证书${plain}"
        fi
    else
        echo -e "${green}复用已有证书，开始安装${plain}"
    fi

    # 设置证书续期重载命令
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}证书续期重载命令默认：${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}该命令会在证书每次续期后自动执行${plain}"
    read -rp "是否修改续期重载命令？(y/n)： " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设：重载Nginx + 重启面板"
        echo -e "${green}\t2.${plain} 自定义命令"
        echo -e "${green}\t0.${plain} 保持默认命令"
        read -rp "请选择： " choice
        case "$choice" in
            1)
                echo -e "${green}已设置为：systemctl reload nginx ; systemctl restart x-ui${plain}"
                reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
                ;;
            2)
                echo -e "${yellow}建议将重启面板命令放在最后${plain}"
                read -rp "请输入自定义命令： " reloadCmd
                echo -e "${green}当前命令：${reloadCmd}${plain}"
                ;;
            *)
                echo -e "${green}保持默认命令${plain}"
                ;;
        esac
    fi

    # 安装证书
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        echo -e "${green}证书安装成功，开启自动续期${plain}"
    else
        echo -e "${red}证书安装失败，退出流程${plain}"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    # 开启自动续期
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}自动续期配置存在异常，当前证书文件如下${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    else
        echo -e "${green}自动续期配置成功，证书文件如下${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    fi

    # 启动面板
    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    # 绑定证书到面板
    read -rp "是否将当前证书设置为面板使用证书？(y/n)： " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}证书路径已同步到面板${plain}"
            echo -e "${green}证书文件：$webCertFile${plain}"
            echo -e "${green}私钥文件：$webKeyFile${plain}"
            echo ""
            echo -e "${green}访问地址：https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}面板将重启以应用SSL证书${plain}"
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            echo -e "${red}错误：未找到对应域名的证书或私钥文件${plain}"
        fi
    else
        echo -e "${yellow}跳过面板证书配置${plain}"
    fi

    return 0
}

# SSL配置交互入口（域名/IP/自定义/跳过）
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"
    local server_ip="$3"

    local ssl_choice=""
    SSL_SCHEME="https"

    echo -e "${yellow}请选择SSL证书配置方式：${plain}"
    echo -e "${green}1.${plain} 域名证书（Let's Encrypt，有效期90天，自动续期）"
    echo -e "${green}2.${plain} IP证书（Let's Encrypt短期证书，有效期6天，自动续期）"
    echo -e "${green}3.${plain} 自定义证书（使用已有的证书文件）"
    echo -e "${green}4.${plain} 跳过SSL（仅适用于反向代理/SSH隧道环境）"
    echo -e "${blue}说明：${plain} 选项1、2需要服务器80端口对外开放；选项3需手动填写证书路径"
    echo -e "${blue}警告：${plain} 选项4为纯HTTP访问，仅建议搭配反向代理或SSH隧道使用"
    read -rp "请选择（默认2，IP证书）： " ssl_choice
    ssl_choice="${ssl_choice// /}"

    # 默认选择2
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
        1)
            echo -e "${green}已选择：域名SSL证书${plain}"
            if ssl_cert_issue; then
                local cert_domain="${SSL_ISSUED_DOMAIN}"
                if [[ -z "${cert_domain}" ]]; then
                    cert_domain=$(~/.acme.sh/acme.sh --list 2> /dev/null | tail -1 | awk '{print $1}')
                fi

                if [[ -n "${cert_domain}" ]]; then
                    SSL_HOST="${cert_domain}"
                    echo -e "${green}✓ 域名SSL证书配置完成：${cert_domain}${plain}"
                else
                    echo -e "${yellow}证书配置完成，但域名识别异常${plain}"
                    SSL_HOST="${server_ip}"
                fi
            else
                echo -e "${red}域名证书配置失败${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        2)
            echo -e "${green}已选择：IP短期SSL证书${plain}"

            local ipv6_addr=""
            read -rp "是否需要绑定IPv6地址？留空则跳过： " ipv6_addr
            ipv6_addr="${ipv6_addr// /}"

            # 关闭面板占用80端口
            if [[ $release == "alpine" ]]; then
                rc-service x-ui stop > /dev/null 2>&1
            else
                systemctl stop x-ui > /dev/null 2>&1
            fi

            setup_ip_certificate "${server_ip}" "${ipv6_addr}"
            if [ $? -eq 0 ]; then
                SSL_HOST="${server_ip}"
                echo -e "${green}✓ IP SSL证书配置完成${plain}"
            else
                echo -e "${red}✗ IP证书配置失败，请检查80端口是否开放${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        3)
            echo -e "${green}已选择：使用自定义证书${plain}"
            local custom_cert=""
            local custom_key=""
            local custom_domain=""

            read -rp "请输入证书对应的域名： " custom_domain
            custom_domain="${custom_domain// /}"

            # 读取证书路径
            while true; do
                read -rp "请输入证书文件路径（后缀.crt / fullchain）： " custom_cert
                custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                    break
                elif [[ ! -f "$custom_cert" ]]; then
                    echo -e "${red}错误：文件不存在，请重新输入${plain}"
                elif [[ ! -r "$custom_cert" ]]; then
                    echo -e "${red}错误：文件无读取权限，请检查权限${plain}"
                else
                    echo -e "${red}错误：文件为空${plain}"
                fi
            done

            # 读取私钥路径
            while true; do
                read -rp "请输入私钥文件路径（后缀.key / privatekey）： " custom_key
                custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                    break
                elif [[ ! -f "$custom_key" ]]; then
                    echo -e "${red}错误：文件不存在，请重新输入${plain}"
                elif [[ ! -r "$custom_key" ]]; then
                    echo -e "${red}错误：文件无读取权限，请检查权限${plain}"
                else
                    echo -e "${red}错误：文件为空${plain}"
                fi
            done

            # 应用证书
            ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" > /dev/null 2>&1

            if [[ -n "$custom_domain" ]]; then
                SSL_HOST="$custom_domain"
            else
                SSL_HOST="${server_ip}"
            fi

            echo -e "${green}✓ 自定义证书路径已生效${plain}"
            echo -e "${yellow}提醒：该证书需你手动续期维护${plain}"

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            ;;
        4)
            echo ""
            echo -e "${red}⚠ 面板将以纯HTTP模式运行（无SSL加密）${plain}"
            echo -e "${yellow}账号密码、Cookie均以明文传输，存在安全风险${plain}"
            echo -e "${yellow}仅推荐以下场景使用：${plain}"
            echo -e "${yellow}  • 前端已有Nginx/Caddy等反向代理处理SSL${plain}"
            echo -e "${yellow}  • 仅通过SSH隧道访问面板${plain}"
            echo ""

            SSL_SCHEME="http"
            SSL_HOST="${server_ip}"

            local bind_local=""
            read -rp "是否仅监听本地127.0.0.1？（推荐，仅内网/隧道可访问）[y/N]： " bind_local
            if [[ "$bind_local" == "y" || "$bind_local" == "Y" ]]; then
                ${xui_folder}/x-ui setting -listenIP "127.0.0.1" > /dev/null 2>&1
                SSL_HOST="127.0.0.1"
                echo -e "${green}✓ 面板已绑定本地地址，外网无法直接访问${plain}"
                echo ""
                echo -e "${green}SSH端口转发 - 本地访问面板命令：${plain}"
                echo -e "  普通SSH连接："
                echo -e "  ${yellow}ssh -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  使用密钥连接："
                echo -e "  ${yellow}ssh -i <密钥路径> -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  然后在浏览器打开："
                echo -e "  ${yellow}http://localhost:2222/${web_base_path}${plain}"
                echo ""
                echo -e "${yellow}也可配置反向代理指向 127.0.0.1:${panel_port} 处理SSL${plain}"
            else
                echo -e "${yellow}面板将监听所有网卡，以纯HTTP对外提供访问，请做好安全防护${plain}"
            fi

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            echo -e "${green}✓ 已跳过SSL配置${plain}"
            ;;
        *)
            echo -e "${red}选项无效，跳过SSL配置${plain}"
            SSL_HOST="${server_ip}"
            ;;
    esac
}

# 安装后初始化配置
config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}自动获取公网IP失败${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请手动输入服务器公网IPv4地址： " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}IPv4格式错误，请重新输入${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 18)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            local db_label="SQLite（文件数据库 /etc/x-ui/x-ui.db）"
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}           数据库选择                    ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "  1) SQLite    （默认，客户端数量小于1000推荐）"
            echo -e "  2) PostgreSQL（高并发/多节点环境推荐）"
            read -rp "请选择 [默认1]： " db_choice
            db_choice="${db_choice:-1}"
            if [[ "$db_choice" == "2" ]]; then
                local xui_env_file
                case "${release}" in
                    ubuntu | debian | armbian)
                        xui_env_file="/etc/default/x-ui"
                        ;;
                    arch | manjaro | parch | alpine)
                        xui_env_file="/etc/conf.d/x-ui"
                        ;;
                    *)
                        xui_env_file="/etc/sysconfig/x-ui"
                        ;;
                esac

                local xui_dsn=""
                local pg_mode=""
                while [[ -z "$xui_dsn" ]]; do
                    echo ""
                    echo -e "  1) 本地自动安装PostgreSQL并创建库表（推荐）"
                    echo -e "  2) 使用已有的PostgreSQL数据库（手动填写连接串）"
                    read -rp "请选择 [默认1]： " pg_mode
                    pg_mode="${pg_mode:-1}"
                    if [[ "$pg_mode" == "2" ]]; then
                        while [[ -z "$xui_dsn" ]]; do
                            read -rp "请输入PostgreSQL连接串 (postgres://账号:密码@地址:端口/库名?sslmode=disable)： " xui_dsn
                            xui_dsn="${xui_dsn// /}"
                        done
                        db_label="PostgreSQL（外部数据库）"
                    else
                        echo -e "${yellow}正在安装PostgreSQL，请稍候...${plain}"
                        if xui_dsn=$(install_postgres_local); then
                            db_label="PostgreSQL（本地 127.0.0.1:5432/xui）"
                        else
                            echo ""
                            echo -e "${red}PostgreSQL 本地安装失败${plain}"
                            echo -e "  1) 重新尝试本地安装"
                            echo -e "  2) 填写外部数据库连接串"
                            echo -e "  3) 终止安装"
                            echo -e "  4) 切换为SQLite"
                            read -rp "请选择 [默认1]： " pg_fail
                            pg_fail="${pg_fail:-1}"
                            case "$pg_fail" in
                                2) pg_mode="2" ;;
                                3) echo -e "${red}安装已终止${plain}"; exit 1 ;;
                                4) db_choice="1"; xui_dsn=""; break ;;
                                *) xui_dsn="" ;;
                            esac
                        fi
                    fi
                done
                if [[ -n "$xui_dsn" ]]; then
                    install -d -m 755 "$(dirname "$xui_env_file")"
                    umask 077
                    cat > "$xui_env_file" << EOF
XUI_DB_TYPE=postgres
XUI_DB_DSN=${xui_dsn}
EOF
                    chmod 600 "$xui_env_file"
                    umask 022
                    export XUI_DB_TYPE=postgres
                    export XUI_DB_DSN="${xui_dsn}"
                fi
            fi

            read -rp "是否自定义面板端口？不自定义则随机生成 [y/n]： " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "请设置面板端口： " config_port
                echo -e "${yellow}当前面板端口：${config_port}${plain}"
            else
                local config_port=$(shuf -i 1024-62000 -n 1)
                echo -e "${yellow}已随机生成端口：${config_port}${plain}"
            fi

            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}           SSL证书配置（强烈推荐）        ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}建议配置SSL加密，仅使用反向代理或SSH隧道时可跳过${plain}"
            echo -e "${yellow}Let's Encrypt 现已支持域名与IP地址证书${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"

            local config_apiToken=$(${xui_folder}/x-ui setting -getApiToken true | grep -Eo 'apiToken: .+' | awk '{print $2}')

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}           面板安装完成                   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}用户名：    ${config_username}${plain}"
            echo -e "${green}密码：      ${config_password}${plain}"
            echo -e "${green}端口：      ${config_port}${plain}"
            echo -e "${green}访问路径：  ${config_webBasePath}${plain}"
            echo -e "${green}数据库：    ${db_label}${plain}"
            echo -e "${green}访问地址：  ${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}API密钥：   ${config_apiToken}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ 重要提醒：请妥善保存以上账号信息！${plain}"
            if [[ "$SSL_SCHEME" == "https" ]]; then
                echo -e "${yellow}⚠ SSL加密：已开启${plain}"
            else
                echo -e "${yellow}⚠ SSL加密：已关闭，当前为纯HTTP模式，请搭配反向代理/隧道使用${plain}"
            fi
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}访问路径过短或缺失，已重新生成随机路径${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}新访问路径：${config_webBasePath}${plain}"

            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}           SSL证书配置（强烈推荐）        ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}Let's Encrypt 支持域名与IP证书${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}访问地址：  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                echo -e "${green}访问地址：https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            echo -e "${yellow}检测到默认账号，已自动重置提升安全性${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "新的登录账号信息："
            echo -e "###############################################"
            echo -e "${green}用户名：${config_username}${plain}"
            echo -e "${green}密码：${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}账号、密码、访问路径均已正常配置${plain}"
        fi

        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}           SSL证书配置（强烈推荐）        ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Let's Encrypt 支持域名与IP证书${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}访问地址：  ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}已配置SSL证书，无需重复操作${plain}"
        fi
    fi

    ${xui_folder}/x-ui migrate
}

# 主安装函数
install_x-ui() {
    cd ${xui_folder%/x-ui}/

    # 下载安装包
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}尝试使用IPv4网络获取版本...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}获取版本号失败，可能是GitHub接口访问受限，请稍后重试${plain}"
                exit 1
            fi
        fi
        echo -e "检测到最新版本：${tag_version}，开始安装..."
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}安装包下载失败，请确认服务器可正常访问GitHub${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"

        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}请使用更新的版本（最低要求 v2.3.5），退出安装。${plain}"
            exit 1
        fi

        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "开始安装 x-ui ${tag_version}"
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui ${tag_version} 失败，请检查该版本是否存在${plain}"
            exit 1
        fi
    fi
    curl -4fLRo /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 x-ui.sh 脚本失败${plain}"
        exit 1
    fi

    # 停止旧服务并清理旧文件
    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm ${xui_folder}/ -rf
    fi

    # 解压安装包并设置执行权限
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f

    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh

    # 根据架构重命名二进制文件
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)

    # 替换系统命令并授权
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install

    # 适配 etckeeper 版本控制，忽略数据库文件
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}已将 x-ui.db 加入 /etc/.gitignore 忽略列表${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}已创建 /etc/.gitignore 并添加 x-ui.db 忽略规则${plain}"
        fi
    fi

    # Alpine 系统使用 rc 服务
    if [[ $release == "alpine" ]]; then
        curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 x-ui.rc 服务文件失败${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # 安装 systemd 服务文件
        service_installed=false

        if [ -f "x-ui.service" ]; then
            echo -e "${green}在压缩包内检测到 x-ui.service，开始安装${plain}"
            cp -f x-ui.service ${xui_service}/ > /dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi

        # 按系统类型匹配对应服务文件
        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}检测到 Debian 系服务文件，开始安装${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}检测到 Arch 系服务文件，开始安装${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}检测到 RHEL 系服务文件，开始安装${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac
        fi

        # 本地无服务文件则从 GitHub 下载
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}压缩包内未找到服务文件，正在从 GitHub 下载${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian > /dev/null 2>&1
                    ;;
                arch | manjaro | parch)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.arch > /dev/null 2>&1
                    ;;
                *)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel > /dev/null 2>&1
                    ;;
            esac

            if [[ $? -ne 0 ]]; then
                echo -e "${red}从 GitHub 下载服务文件失败${plain}"
                exit 1
            fi
            service_installed=true
        fi

        # 重载系统服务并启动
        if [ "$service_installed" = true ]; then
            echo -e "${green}正在配置 systemd 服务单元${plain}"
            chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}安装 x-ui 服务文件失败${plain}"
            exit 1
        fi
    fi

    echo -e "${green}x-ui ${tag_version}${plain} 安装完成，服务已正常运行..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui 管理脚本使用说明：${plain}                        │
│                                                       │
│  ${blue}x-ui${plain}              打开管理菜单                  │
│  ${blue}x-ui start${plain}        启动服务                    │
│  ${blue}x-ui stop${plain}         停止服务                    │
│  ${blue}x-ui restart${plain}      重启服务                    │
│  ${blue}x-ui status${plain}       查看运行状态                 │
│  ${blue}x-ui settings${plain}     查看面板配置                 │
│  ${blue}x-ui enable${plain}       设置开机自启                │
│  ${blue}x-ui disable${plain}      关闭开机自启                │
│  ${blue}x-ui log${plain}          查看运行日志                │
│  ${blue}x-ui banlog${plain}       查看封禁日志                │
│  ${blue}x-ui update${plain}       在线升级                    │
│  ${blue}x-ui legacy${plain}       切换至旧版本                │
│  ${blue}x-ui install${plain}      重新安装                    │
│  ${blue}x-ui uninstall${plain}    卸载程序                    │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}开始执行安装流程...${plain}"
install_base
install_x-ui $1
       
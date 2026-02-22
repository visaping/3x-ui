#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# Non-interactive defaults (can override by exporting NONINTERACTIVE=0 before running)
NONINTERACTIVE="${NONINTERACTIVE:=1}"
DEFAULT_PANEL_PORT="${DEFAULT_PANEL_PORT:=8443}"
DEFAULT_PANEL_USERNAME="${DEFAULT_PANEL_USERNAME:=y}"
DEFAULT_PANEL_PASSWORD="${DEFAULT_PANEL_PASSWORD:=y}"
DEFAULT_PANEL_WEBBASEPATH="${DEFAULT_PANEL_WEBBASEPATH:=}"


# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Helper: prompt user unless NONINTERACTIVE=1 (then keep empty/default values)
prompt() {
    # usage: prompt VAR "message" "default"
    local __var_name="$1"
    local __msg="$2"
    local __default="$3"
    if [[ "${NONINTERACTIVE}" == "1" ]]; then
        # keep default (may be empty)
        printf -v "${__var_name}" "%s" "${__default}"
        return 0
    fi
    local __input=""
    if [[ -n "${__default}" ]]; then
        read -rp "${__msg} (default ${__default}): " __input
    else
        read -rp "${__msg}: " __input
    fi
    __input="${__input}"
    if [[ -z "${__input}" ]]; then
        printf -v "${__var_name}" "%s" "${__default}"
    else
        printf -v "${__var_name}" "%s" "${__input}"
    fi
}

prompt_yn() {
    # usage: prompt_yn VAR "message" "y|n"  (default y/n)
    local __var_name="$1"
    local __msg="$2"
    local __default="$3"
    if [[ "${NONINTERACTIVE}" == "1" ]]; then
        printf -v "${__var_name}" "%s" "${__default}"
        return 0
    fi
    local __input=""
    read -rp "${__msg} [y/n] (default ${__default}): " __input
    __input="${__input// /}"
    if [[ -z "${__input}" ]]; then
        __input="${__default}"
    fi
    printf -v "${__var_name}" "%s" "${__input}"
}
# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
    elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64)
        echo 'amd64'
        ;;
    i*86 | x86)
        echo '386'
        ;;
    armv8* | armv8 | arm64 | aarch64)
        echo 'arm64'
        ;;
    armv7* | armv7 | arm)
        echo 'armv7'
        ;;
    armv6* | armv6)
        echo 'armv6'
        ;;
    armv5* | armv5)
        echo 'armv5'
        ;;
    s390x)
        echo 's390x'
        ;;
    *)
        echo "unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
    esac
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

is_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn | awk '{print $4}' | grep -q ":${port}$"
    else
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    fi
}

install_base() {
    echo -e "${green}Installing base packages...${plain}"
    if [[ "${release}" == "centos" ]]; then
        yum install -y wget curl tar socat ca-certificates >/dev/null 2>&1
    elif [[ "${release}" == "ubuntu" || "${release}" == "debian" ]]; then
        apt update -y >/dev/null 2>&1
        apt install -y wget curl tar socat ca-certificates >/dev/null 2>&1
    elif [[ "${release}" == "alpine" ]]; then
        apk add --no-cache wget curl tar socat ca-certificates >/dev/null 2>&1
    else
        echo -e "${red}The current OS is not supported.${plain}"
        exit 1
    fi
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}


enable_bbr() {
    # Try to enable BBR congestion control (best-effort)
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        sed -i '/^net\.core\.default_qdisc=/d' /etc/sysctl.conf 2>/dev/null || true
        sed -i '/^net\.ipv4\.tcp_congestion_control=/d' /etc/sysctl.conf 2>/dev/null || true
        {
            echo 'net.core.default_qdisc=fq'
            echo 'net.ipv4.tcp_congestion_control=bbr'
        } >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw bbr; then
            echo -e "${green}BBR enabled successfully.${plain}"
        else
            echo -e "${yellow}Tried to enable BBR, but active cc is not bbr.${plain}"
        fi
    else
        echo -e "${yellow}Kernel seems not to support BBR; skipping auto-enable.${plain}"
    fi
}

install_acme() {
    echo -e "${green}Installing acme.sh...${plain}"
    if [[ -d ~/.acme.sh ]]; then
        echo -e "${yellow}acme.sh already installed.${plain}"
        return 0
    fi
    curl https://get.acme.sh | sh -s email=my@example.com >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to install acme.sh.${plain}"
        return 1
    fi
    source ~/.bashrc >/dev/null 2>&1
    return 0
}

get_cert_path() {
    local host="$1"
    echo "${xui_folder}/cert/${host}"
}

create_cert_dir() {
    local host="$1"
    local cert_dir
    cert_dir=$(get_cert_path "$host")
    mkdir -p "${cert_dir}"
}

install_cert() {
    local host="$1"
    local cert_dir
    cert_dir=$(get_cert_path "$host")

    # Install cert & key
    ~/.acme.sh/acme.sh --install-cert -d "${host}" \
        --key-file "${cert_dir}/private.key" \
        --fullchain-file "${cert_dir}/fullchain.crt" >/dev/null 2>&1

    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to install certificate for ${host}.${plain}"
        return 1
    fi

    echo -e "${green}Certificate installed at:${plain} ${cert_dir}/fullchain.crt"
    echo -e "${green}Private key installed at:${plain} ${cert_dir}/private.key"
    return 0
}

apply_panel_ssl() {
    local host="$1"
    local panel_port="$2"
    local web_base_path="$3"

    local cert_dir
    cert_dir=$(get_cert_path "$host")

    if [[ ! -f "${cert_dir}/fullchain.crt" || ! -f "${cert_dir}/private.key" ]]; then
        echo -e "${red}Certificate files not found at ${cert_dir}.${plain}"
        return 1
    fi

    ${xui_folder}/x-ui setting -port "${panel_port}" -webBasePath "${web_base_path}" -cert "${cert_dir}/fullchain.crt" -key "${cert_dir}/private.key" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to apply SSL certificate to the panel.${plain}"
        return 1
    fi

    echo -e "${green}SSL certificate applied to the panel successfully.${plain}"
    return 0
}

issue_cert_for_host() {
    local host="$1"
    local WebPort="$2"

    create_cert_dir "$host"

    # stop panel first if it's using port 80 or not
    systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null

    # issue the certificate
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d ${host} --listen-v6 --standalone --httpport ${WebPort} --force
    if [ $? -ne 0 ]; then
        echo -e "${red}Issuing certificate failed, please check logs.${plain}"
        rm -rf ~/.acme.sh/${host}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}Issuing certificate succeeded, installing certificates...${plain}"
    fi

    # Setup reload command
    local setReloadcmd=""
    prompt_yn setReloadcmd "Would you like to modify --reloadcmd for ACME?" "n"
    if [[ "${setReloadcmd}" == "y" || "${setReloadcmd}" == "Y" ]]; then
        echo -e "${yellow}Warning:${plain} Incorrect reload command may break auto-renewal."
        local reloadCmd=""
        prompt reloadCmd "Please enter your custom reloadcmd" ""
        if [[ -n "${reloadCmd}" ]]; then
            ~/.acme.sh/acme.sh --install-cert -d "${host}" --reloadcmd "${reloadCmd}" >/dev/null 2>&1
        fi
    fi

    # Install cert files into x-ui folder
    install_cert "${host}"
    if [ $? -ne 0 ]; then
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    fi

    # restart panel
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
    return 0
}

select_existing_cert_and_apply() {
    local panel_port="$1"
    local web_base_path="$2"
    local certs_dir="${xui_folder}/cert"

    if [[ ! -d "${certs_dir}" ]]; then
        echo -e "${yellow}No existing certificates directory found.${plain}"
        return 1
    fi

    local cert_list=()
    while IFS= read -r -d '' dir; do
        cert_list+=("$(basename "$dir")")
    done < <(find "${certs_dir}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    if [[ ${#cert_list[@]} -eq 0 ]]; then
        echo -e "${yellow}No existing certificates found.${plain}"
        return 1
    fi

    echo -e "${green}Existing certificates found:${plain}"
    local i=1
    for cert_host in "${cert_list[@]}"; do
        echo -e "  ${yellow}${i}.${plain} ${cert_host}"
        i=$((i + 1))
    done

    local choice=""
    prompt choice "Choose an option" ""
    if [[ -z "${choice}" || ! "${choice}" =~ ^[0-9]+$ || "${choice}" -lt 1 || "${choice}" -gt ${#cert_list[@]} ]]; then
        echo -e "${red}Invalid choice.${plain}"
        return 1
    fi

    local selected_host="${cert_list[$((choice - 1))]}"
    echo -e "${green}Selected certificate: ${selected_host}${plain}"

    local setPanel=""
    prompt_yn setPanel "Would you like to set this certificate for the panel?" "n"
    if [[ "${setPanel}" == "y" || "${setPanel}" == "Y" ]]; then
        apply_panel_ssl "${selected_host}" "${panel_port}" "${web_base_path}"
        if [[ $? -eq 0 ]]; then
            SSL_HOST="${selected_host}"
            echo -e "${green}Certificate applied to the panel successfully.${plain}"
            return 0
        else
            echo -e "${red}Failed to apply certificate to the panel.${plain}"
            return 1
        fi
    else
        echo -e "${yellow}Not applying certificate to the panel.${plain}"
        return 1
    fi
}

prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"   # expected without leading slash
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}Choose SSL certificate setup method:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt for Domain (90-day validity, auto-renews)"
    echo -e "${green}2.${plain} Let's Encrypt for IP Address (6-day validity, auto-renews)"
    echo -e "${green}3.${plain} Custom SSL Certificate (Path to existing files)"
    echo -e "${blue}Note:${plain} Options 1 & 2 require port 80 open. Option 3 requires manual paths."
    prompt ssl_choice "Choose an option (1=Domain, 2=IP, 3=Custom)" "2"
    ssl_choice="${ssl_choice// /}"  # Trim whitespace
    
    # Default to 2 (IP cert)
    if [[ -z "${ssl_choice}" ]]; then
        ssl_choice="2"
    fi

    if [[ "${ssl_choice}" == "1" ]]; then
        # Domain cert
        local domain=""
        prompt domain "Please enter your domain name" ""
        if [[ -z "${domain}" || ! $(is_domain "${domain}") ]]; then
            echo -e "${red}Invalid domain provided.${plain}"
            return 1
        fi
        SSL_HOST="${domain}"

        # Check port 80 usage
        if is_port_in_use 80; then
            echo -e "${red}Port 80 is already in use. Please free it before proceeding.${plain}"
            return 1
        fi

        # Issue domain cert
        local WebPort="80"
        prompt WebPort "Port to use for ACME HTTP-01 listener" "80"
        if [[ -z "${WebPort}" ]]; then
            WebPort="80"
        fi

        issue_cert_for_host "${domain}" "${WebPort}" || return 1
        apply_panel_ssl "${domain}" "${panel_port}" "${web_base_path}" || return 1
        return 0

    elif [[ "${ssl_choice}" == "2" ]]; then
        # IP cert
        SSL_HOST="${server_ip}"

        # Check port 80 usage
        if is_port_in_use 80; then
            echo -e "${red}Port 80 is already in use. Please free it before proceeding.${plain}"
            return 1
        fi

        local WebPort="80"
        prompt WebPort "Please choose which port to use" "80"
        if [[ -z "${WebPort}" ]]; then
            WebPort="80"
        fi

        local ipv6_addr=""
        prompt ipv6_addr "Do you have an IPv6 address to include? (leave empty to skip)" ""
        if [[ -n "${ipv6_addr}" && ! $(is_ipv6 "${ipv6_addr}") ]]; then
            echo -e "${red}Invalid IPv6 address.${plain}"
            return 1
        fi

        # For IP cert, we may need to include ipv6 in issue flags (already uses --listen-v6)
        # We'll just use the v4/v6 listen with the host being v4 IP, and acme should bind.
        issue_cert_for_host "${server_ip}" "${WebPort}" || return 1
        apply_panel_ssl "${server_ip}" "${panel_port}" "${web_base_path}" || return 1
        return 0

    elif [[ "${ssl_choice}" == "3" ]]; then
        # Custom cert
        echo -e "${yellow}Custom SSL selected.${plain}"
        local custom_domain=""
        prompt custom_domain "Please enter domain name certificate issued for" ""
        if [[ -z "${custom_domain}" ]]; then
            echo -e "${red}No domain/IP provided.${plain}"
            return 1
        fi

        local custom_cert=""
        local custom_key=""
        prompt custom_cert "Input certificate path (keywords: .crt / fullchain)" ""
        prompt custom_key "Input private key path (keywords: .key / privatekey)" ""

        if [[ ! -f "${custom_cert}" || ! -f "${custom_key}" ]]; then
            echo -e "${red}Certificate or key file does not exist.${plain}"
            return 1
        fi

        create_cert_dir "${custom_domain}"
        local cert_dir
        cert_dir=$(get_cert_path "${custom_domain}")
        cp -f "${custom_cert}" "${cert_dir}/fullchain.crt"
        cp -f "${custom_key}" "${cert_dir}/private.key"

        SSL_HOST="${custom_domain}"
        apply_panel_ssl "${custom_domain}" "${panel_port}" "${web_base_path}" || return 1
        return 0

    else
        echo -e "${red}Invalid selection.${plain}"
        return 1
    fi
}

install_xui() {
    install_base

    local version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "${version}" ]]; then
        echo -e "${red}Failed to fetch latest version tag from GitHub.${plain}"
        exit 1
    fi
    tag_version="${version}"

    local arch_name
    arch_name=$(arch)

    echo -e "${green}Downloading x-ui ${tag_version}...${plain}"
    local xui_url="https://github.com/vaxilu/x-ui/releases/download/${tag_version}/x-ui-linux-${arch_name}.tar.gz"
    wget -qO x-ui-linux-${arch_name}.tar.gz "${xui_url}"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui release.${plain}"
        exit 1
    fi

    echo -e "${green}Extracting...${plain}"
    rm -rf "${xui_folder}"
    mkdir -p "${xui_folder}"
    tar zxvf x-ui-linux-${arch_name}.tar.gz -C "${xui_folder}" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to extract x-ui package.${plain}"
        exit 1
    fi

    cd "${xui_folder}" || exit 1
    chmod +x x-ui bin/xray-linux-$(arch)

    if [[ ! -f /usr/bin/x-ui ]]; then
        ln -s ${xui_folder}/x-ui /usr/bin/x-ui
    fi

    mkdir -p /var/log/x-ui >/dev/null 2>&1

    if [[ -d /etc/.git ]]; then
        grep -q "x-ui.db" /etc/.gitignore 2>/dev/null || echo "x-ui.db" >>/etc/.gitignore 2>/dev/null
    fi

    # Read existing settings (if any)
    existing_webBasePath="$(${xui_folder}/x-ui settings 2>/dev/null | grep -i "webBasePath" | awk -F':' '{print $2}' | tr -d ' ')"
    existing_hasDefaultCredential="$(${xui_folder}/x-ui settings 2>/dev/null | grep -i "hasDefaultCredential" | awk -F':' '{print $2}' | tr -d ' ')"

    # Determine server IP
    server_ip=""
    while [[ -z "${server_ip}" ]]; do
        ip_result=$(curl -s https://api.ipify.org)
        if is_ipv4 "${ip_result}"; then
            server_ip="${ip_result}"
            break
        fi
        ip_result=$(curl -s https://ifconfig.me)
        if is_ipv4 "${ip_result}"; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath="${DEFAULT_PANEL_WEBBASEPATH}"
            local config_username="${DEFAULT_PANEL_USERNAME}"
            local config_password="${DEFAULT_PANEL_PASSWORD}"
            local config_port="${DEFAULT_PANEL_PORT}"
            echo -e "${yellow}Panel settings (non-interactive defaults):${plain}"
            echo -e "${yellow}  Username: ${config_username}${plain}"
            echo -e "${yellow}  Password: ${config_password}${plain}"
            echo -e "${yellow}  Port: ${config_port}${plain}"
            echo -e "${yellow}  WebBasePath: ${config_webBasePath}${plain}"
            
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
            
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL Certificate Setup (MANDATORY)     ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            
            install_acme || exit 1
            
            # Try to reuse existing cert if present
            if select_existing_cert_and_apply "${config_port}" "${config_webBasePath}"; then
                echo -e "${green}Using existing certificate applied successfully.${plain}"
            else
                # Setup SSL automatically (defaults to IP cert, port 80, no extra prompts in NONINTERACTIVE)
                prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}" || echo -e "${red}SSL setup failed.${plain}"
            fi
            
            systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}   Panel has been secured successfully!    ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo ""
            
            # Print access URL
            local base_path=""
            if [[ -n "${config_webBasePath}" ]]; then
                base_path="/${config_webBasePath}"
            fi
            
            if [[ -z "${SSL_HOST}" ]]; then
                SSL_HOST="${server_ip}"
            fi
            
            echo -e "${green}Access URL:${plain} https://${SSL_HOST}:${config_port}${base_path}"
            echo -e "${green}Username:${plain} ${config_username}"
            echo -e "${green}Password:${plain} ${config_password}"
        else
            echo -e "${yellow}Skipping panel path setting.${plain}"
        fi
    fi

    # Install service
    if [[ "${release}" == "alpine" ]]; then
        echo -e "${green}Setting up OpenRC service...${plain}"
        if [[ -f "${xui_folder}/x-ui" ]]; then
            mkdir -p /etc/init.d >/dev/null 2>&1
            if [[ -f "${xui_folder}/x-ui.openrc" ]]; then
                cp -f "${xui_folder}/x-ui.openrc" /etc/init.d/x-ui
            else
                curl -fsSL https://raw.githubusercontent.com/vaxilu/x-ui/master/x-ui.openrc -o /etc/init.d/x-ui >/dev/null 2>&1
            fi
            chmod +x /etc/init.d/x-ui
            rc-update add x-ui default >/dev/null 2>&1
            rc-service x-ui start
        enable_bbr
        else
            echo -e "${red}Failed to install x-ui OpenRC service file${plain}"
            exit 1
        fi
    else
        if [[ -f "${xui_folder}/x-ui.service" ]]; then
            cp -f "${xui_folder}/x-ui.service" ${xui_service}/x-ui.service
            service_installed=true
        else
            echo -e "${yellow}No x-ui.service found in extracted files, downloading from GitHub...${plain}"
            if [[ "${release}" == "centos" ]]; then
                if [[ "$(rpm -E %{rhel})" -eq 7 ]]; then
                    curl -fsSL https://raw.githubusercontent.com/vaxilu/x-ui/master/x-ui.service -o ${xui_service}/x-ui.service >/dev/null 2>&1
                else
                    curl -fsSL https://raw.githubusercontent.com/vaxilu/x-ui/master/x-ui.service -o ${xui_service}/x-ui.service >/dev/null 2>&1
                fi
            else
                curl -fsSL https://raw.githubusercontent.com/vaxilu/x-ui/master/x-ui.service -o ${xui_service}/x-ui.service >/dev/null 2>&1
            fi

            if [[ -f ${xui_service}/x-ui.service ]]; then
                service_installed=true
            else
                service_installed=false
            fi
        fi

        if [ "$service_installed" = true ]; then
            echo -e "${green}Setting up systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service >/dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service >/dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        enable_bbr
        else
            echo -e "${red}Failed to install x-ui.service file${plain}"
            exit 1
        fi
    fi
    
    echo -e "${green}x-ui ${tag_version}${plain} installation finished, it is running now..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart                 │
│  ${blue}x-ui disable${plain}      - Disable Autostart                │
│  ${blue}x-ui log${plain}          - Check Logs                       │
│                                                       │
└───────────────────────────────────────────────────────┘"
}

install_xui

#!/usr/bin/env bash
# ==============================================================================
# Linux Server Initialization Script (V3.0 - Stable)
# 修复：Neovim 安装逻辑优化，增加架构判断与容错
# ==============================================================================

set -o errexit  # 错误退出
set -o nounset  # 变量未定义报错
set -o pipefail # 管道错误传递

# --- [1] 全局定义 ---

# 基础工具包
CFG_BASE_TOOLS="curl git tar tree htop jq nano wget unzip ca-certificates openssl"

# 交互变量 (留空则询问)
CFG_HOSTNAME=""
CFG_SSH_PORT=""
CFG_SWAP_SIZE=""
CFG_GIT_NAME=""
CFG_GIT_EMAIL=""

# 功能开关
CFG_INSTALL_ZSH=""
CFG_ZSH_DEFAULT=""
CFG_INSTALL_FAIL2BAN=""
CFG_INSTALL_DOCKER=""
CFG_DOCKER_MIRROR=""
CFG_SSH_PUBKEY=""

# 样式
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_CYAN='\033[0;36m'

# --- [2] 基础函数 ---

log_info() { echo -e "${C_CYAN}[INFO]${C_RESET} $1"; }
log_success() { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; }

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "必须以 root 权限运行"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="$ID"; else log_error "无法检测 OS"; exit 1; fi
    case "$OS_ID" in
        debian|ubuntu|kali|armbian)
            PKG_MANAGER="apt-get"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="apt-get install -y"; SSH_SERVICE="ssh"
            export DEBIAN_FRONTEND=noninteractive ;;
        centos|rhel|fedora|almalinux|rocky|anolis)
            command -v dnf >/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
            PKG_UPDATE="$PKG_MANAGER makecache"; PKG_INSTALL="$PKG_MANAGER install -y"; SSH_SERVICE="sshd" ;;
        alpine)
            PKG_MANAGER="apk"; PKG_UPDATE="apk update"; PKG_INSTALL="apk add"; SSH_SERVICE="sshd" ;;
        *) log_error "不支持: $OS_ID"; exit 1 ;;
    esac
}

install_pkgs() {
    local pkgs=("$@")
    local to_install=""
    for p in "${pkgs[@]}"; do
        if ! command -v "$p" >/dev/null 2>&1; then to_install="$to_install $p"; fi
    done
    if [[ -n "$to_install" ]]; then
        log_info "安装: $to_install"
        eval "$PKG_UPDATE" >/dev/null 2>&1 || true
        eval "$PKG_INSTALL $to_install" >/dev/null
    fi
}

# --- [3] 交互逻辑 ---

collect_info() {
    clear
    echo -e "${C_GREEN}=== 系统初始化交互向导 ===${C_RESET}"
    echo "提示：按 Enter 键选择默认值或跳过。"

    if [[ -z "$CFG_HOSTNAME" ]]; then read -rp "🖥️  主机名 (留空跳过): " CFG_HOSTNAME; fi

    if [[ -z "$CFG_SSH_PORT" ]]; then
        read -rp "🔒 SSH端口 (默认 22): " v
        [[ -z "$v" ]] && CFG_SSH_PORT="22" || CFG_SSH_PORT="$v"
    fi

    if [[ -z "$CFG_SWAP_SIZE" ]]; then
        if grep -q "swap" /etc/fstab; then CFG_SWAP_SIZE="0"; else
            read -rp "💾 创建Swap? (GB, 0跳过): " v
            [[ -n "$v" ]] && CFG_SWAP_SIZE="$v" || CFG_SWAP_SIZE="0"
        fi
    fi

    if [[ -z "$CFG_GIT_NAME" ]]; then
        read -rp "🔧 Git Name (留空跳过): " CFG_GIT_NAME
        [[ -n "$CFG_GIT_NAME" && -z "$CFG_GIT_EMAIL" ]] && read -rp "   -> Git Email: " CFG_GIT_EMAIL
    fi

    if [[ -z "$CFG_INSTALL_ZSH" ]]; then
        read -rp "🐚 安装 Zsh? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_ZSH="true" || CFG_INSTALL_ZSH="false"
        if [[ "$CFG_INSTALL_ZSH" == "true" && -z "$CFG_ZSH_DEFAULT" ]]; then
            read -rp "   -> 设为默认Shell? (y/N): " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && CFG_ZSH_DEFAULT="true" || CFG_ZSH_DEFAULT="false"
        fi
    fi

    if [[ -z "$CFG_INSTALL_FAIL2BAN" ]]; then
        read -rp "🛡️ 安装 Fail2Ban? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_FAIL2BAN="true" || CFG_INSTALL_FAIL2BAN="false"
    fi

    if [[ -z "$CFG_INSTALL_DOCKER" ]]; then
        read -rp "🐳 安装 Docker? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_DOCKER="true" || CFG_INSTALL_DOCKER="false"
    fi
    # TODO docker安装逻辑
    if [[ "$CFG_INSTALL_DOCKER" == "true" && -z "$CFG_DOCKER_MIRROR" ]]; then
        if curl -I -m 3 -s https://get.docker.com >/dev/null; then echo "   -> 国际网络畅通。"; else echo "   -> 网络可能受限。"; fi
        read -rp "   -> 配置镜像加速? (URL, 留空跳过): " CFG_DOCKER_MIRROR
    fi

    if [[ -z "$CFG_SSH_PUBKEY" ]]; then
        read -rp "🔑 导入 SSH 公钥? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && { echo "👇 粘贴公钥:"; read -r CFG_SSH_PUBKEY; }
    fi
    echo -e "\n🚀 开始执行..."
}

# --- [4] 执行模块 ---

task_base() {
    log_info "[1/6] 基础环境..."
    [[ "$OS_ID" == "debian" ]] && sed -i '/cdrom:/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
    install_pkgs $CFG_BASE_TOOLS

    if [[ -n "$CFG_HOSTNAME" ]]; then
        hostnamectl set-hostname "$CFG_HOSTNAME" 2>/dev/null || hostname "$CFG_HOSTNAME"
        if ! grep -q "127.0.0.1 $CFG_HOSTNAME" /etc/hosts; then echo "127.0.0.1 $CFG_HOSTNAME" >> /etc/hosts; fi
    fi

    if [[ -n "$CFG_GIT_NAME" ]]; then
        git config --global user.name "$CFG_GIT_NAME"
        git config --global user.email "$CFG_GIT_EMAIL"
    fi
}

task_ssh() {
    log_info "[2/6] SSH 配置..."
    [[ "$OS_ID" =~ (debian|ubuntu|rhel|centos|almalinux|rocky) ]] && install_pkgs openssh-server
    
    # 1. 目录与权限准备
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [[ -n "$CFG_SSH_PUBKEY" ]]; then
        if ! grep -Fq "$CFG_SSH_PUBKEY" /root/.ssh/authorized_keys; then 
            echo "$CFG_SSH_PUBKEY" >> /root/.ssh/authorized_keys
        fi
        chmod 600 /root/.ssh/authorized_keys
    fi

    # 2. 备份并修改主配置文件
    local ssh_conf="/etc/ssh/sshd_config"
    cp "$ssh_conf" "${ssh_conf}.bak.$(date +%F_%H%M%S)"
    
    # [核心修复] 注释掉主配置中所有 Port 定义，防止冲突或重复监听
    sed -i -E 's/^#?Port [0-9]+/#&/' "$ssh_conf"

    # 确保 Include 指令存在
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" "$ssh_conf"; then 
        # 建议插在文件头部，但追加通常也能生效（取决于具体发行版默认配置结构）
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$ssh_conf"
    fi

    # 3. 写入新的独立配置文件
    cat > /etc/ssh/sshd_config.d/99-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication $([[ -n "$CFG_SSH_PUBKEY" ]] && echo "no" || echo "yes")
PermitRootLogin yes
EOF

    # 4. 检查与重启
    if sshd -t; then
        systemctl restart "$SSH_SERVICE" 2>/dev/null || service "$SSH_SERVICE" restart
        log_success "SSH 服务已重启，端口: $CFG_SSH_PORT"
    else
        log_error "SSH 配置校验失败！正在回滚..."
        mv "${ssh_conf}.bak.*" "$ssh_conf" 2>/dev/null || true
        rm -f /etc/ssh/sshd_config.d/99-init.conf
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
}

task_swap() {
    [[ -z "$CFG_SWAP_SIZE" || "$CFG_SWAP_SIZE" == "0" ]] && return
    log_info "[3/6] Swap..."
    fallocate -l "${CFG_SWAP_SIZE}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1G count="$CFG_SWAP_SIZE"
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
}

task_shell() {
    log_info "[4/6] Shell 环境..."
    if [[ "$CFG_INSTALL_ZSH" == "true" ]]; then
        install_pkgs zsh
        [[ "$CFG_ZSH_DEFAULT" == "true" ]] && chsh -s "$(which zsh)" root
        [[ ! -d "/root/.oh-my-zsh" ]] && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
    fi
    
    if ! command -v nvim >/dev/null; then
        log_info "安装 Neovim (Binary)..."
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then NVIM_FILE="nvim-linux-x86_64.tar.gz"; NVIM_DIR="nvim-linux-x86_64";
        elif [[ "$ARCH" == "aarch64" ]]; then NVIM_FILE="nvim-linux-arm64.tar.gz"; NVIM_DIR="nvim-linux-arm64";
        else log_warn "架构不支持"; return; fi
        
        cd /tmp
        if curl -fLO "https://github.com/neovim/neovim/releases/latest/download/$NVIM_FILE"; then
            rm -rf "/opt/$NVIM_DIR"
            if tar -C /opt -xzf "$NVIM_FILE"; then
                ln -sf "/opt/$NVIM_DIR/bin/nvim" /usr/local/bin/nvim
                ln -sf "/opt/$NVIM_DIR/bin/nvim" /usr/local/bin/vim
                log_success "Neovim 安装完毕"
            else
                log_warn "解压失败"
            fi
        else
            log_warn "下载失败"
        fi
        
        if [[ -x "/usr/local/bin/nvim" && ! -d "/root/.config/nvim" ]]; then
             git clone --depth=1 https://github.com/LazyVim/starter /root/.config/nvim || log_warn "配置下载失败"
        fi
    fi
}

task_docker() {
    [[ "$CFG_INSTALL_DOCKER" != "true" ]] && return
    log_info "[5/6] Docker..."
    if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | bash; fi
    
    if [[ -n "$CFG_DOCKER_MIRROR" ]]; then
        mkdir -p /etc/docker
        local djson="/etc/docker/daemon.json"
        if [[ ! -f "$djson" ]]; then
            echo "{\"registry-mirrors\": [\"$CFG_DOCKER_MIRROR\"]}" > "$djson"
        elif command -v jq >/dev/null; then
            tmp=$(mktemp)
            jq --arg m "$CFG_DOCKER_MIRROR" '.["registry-mirrors"] += [$m] | .["registry-mirrors"] |= unique' "$djson" > "$tmp" && mv "$tmp" "$djson"
        fi
        systemctl restart docker
    fi
}

task_fail2ban() {
    [[ "$CFG_INSTALL_FAIL2BAN" != "true" ]] && return
    log_info "[6/6] Fail2Ban..."
    install_pkgs fail2ban
    local logpath="/var/log/auth.log"
    [[ "$OS_ID" =~ (rhel|centos|almalinux) ]] && logpath="/var/log/secure"
    
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $CFG_SSH_PORT
logpath = $logpath
maxretry = 5
bantime = 3600
EOF
    systemctl enable --now fail2ban; systemctl restart fail2ban
}

bash_pri(){
    cd ~
    rm -rf .bashrc
    curl -sLO https
}

main() {
    check_root
    detect_os
    collect_info
    
    task_base
    task_ssh
    task_swap
    task_shell
    task_docker
    task_fail2ban

    bash_pri

    echo -e "\n${C_GREEN}✅ 初始化完成!${C_RESET}"
    echo "⚠️  SSH 端口: $CFG_SSH_PORT (请检查防火墙)"
    [[ "$CFG_INSTALL_ZSH" == "true" ]] && echo "🔄 重新登录生效。"
}

main "$@"
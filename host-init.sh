#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# --- [1] 全局定义 ---

# 基础工具包
CFG_BASE_TOOLS="curl git tar tree htop vim jq nano wget unzip ca-certificates openssl bash-completion sudo"

# 环境状态变量
OS_ID=""
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
SSH_SERVICE=""
TARGET_USER_1000=""
CFG_INTERNATIONAL_NETWORK=""
IS_PVE="false"

# 交互配置变量 (将在 collect_info 中填充)
CFG_HOSTNAME=""
CFG_SSH_PORT=""
CFG_SWAP_SIZE=""
CFG_GIT_NAME=""
CFG_GIT_EMAIL=""
CFG_INSTALL_ZSH=""
CFG_ZSH_DEFAULT=""
CFG_INSTALL_FAIL2BAN=""
CFG_FAIL2BAN_PVE=""
CFG_FAIL2BAN_RECIDIVE=""
CFG_RECIDIVE_BANTIME=""
CFG_INSTALL_DOCKER=""
CFG_DOCKER_MIRROR=""
CFG_SSH_PUBKEY=""
CFG_SSH_PASSWDLOGIN=""
CFG_BASHRC_TARGET=""

# 样式
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_CYAN='\033[0;36m'

# --- [2] 基础函数 & 环境检测 ---

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

detect_env() {
    # 1. 检测 OS
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

    # 2. 检测 PVE 环境 (Proxmox VE)
    # PVE 的 ID 是 "proxmox"，且通常存在 /etc/pve 目录
    if [[ "$OS_ID" == "proxmox" ]] || [[ -d /etc/pve ]]; then
        IS_PVE="true"
        log_info "检测到 Proxmox VE 环境"
    fi

    # 3. 检测网络 (提前至此处，供后续决策使用)
    log_info "正在检测网络环境..."
    if curl -I -s --connect-timeout 3 https://www.google.com >/dev/null; then
        CFG_INTERNATIONAL_NETWORK="true"
        log_success "网络环境: 国际互联 (International)"
    else
        CFG_INTERNATIONAL_NETWORK="false"
        log_warn "网络环境: 国内/受限 (Mainland China)"
    fi

    # 4. 检测 UID 1000 用户
    TARGET_USER_1000=$(id -nu 1000 2>/dev/null || true)
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
        eval "$PKG_INSTALL $to_install"
    fi
}

# --- [3] 交互收集模块 ---

collect_info() {
    echo -e "${C_GREEN}=== 系统初始化交互向导 ===${C_RESET}"
    echo "提示：按 Enter 键选择默认值或跳过。"

    # 1. 主机名
    if [[ -z "$CFG_HOSTNAME" ]]; then read -rp "🖥️  主机名 (留空跳过): " CFG_HOSTNAME; fi

    # 2. SSH 端口
    if [[ -z "$CFG_SSH_PORT" ]]; then
        local current_port=""

        if command -v sshd >/dev/null; then
            current_port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)
        fi

        read -rp "🔒 SSH端口 (默认 ${current_port}): " v
        [[ -z "$v" ]] && CFG_SSH_PORT="$current_port" || CFG_SSH_PORT="$v"
    fi

    # 3. Swap
    if [[ -z "$CFG_SWAP_SIZE" ]]; then
        if grep -q "swap" /etc/fstab; then CFG_SWAP_SIZE="0"; else
            read -rp "💾 创建Swap? (GB, 0跳过): " v
            [[ -n "$v" ]] && CFG_SWAP_SIZE="$v" || CFG_SWAP_SIZE="0"
        fi
    fi

    # 4. Git 配置
    if [[ -z "$CFG_GIT_NAME" ]]; then
        read -rp "🔧 Git Name (留空跳过): " CFG_GIT_NAME
        [[ -n "$CFG_GIT_NAME" && -z "$CFG_GIT_EMAIL" ]] && read -rp "   -> Git Email: " CFG_GIT_EMAIL
    fi

    # 5. .bashrc 个性化配置范围
    if [[ -n "$TARGET_USER_1000" ]]; then
        echo -e "\n👤 检测到 UID 1000 用户: ${C_CYAN}${TARGET_USER_1000}${C_RESET}"
        read -rp "📝 配置个人环境(.bashrc)范围? [1: 仅Root / 2: Root + ${TARGET_USER_1000}] (默认2): " v
        if [[ "$v" == "1" ]]; then
            CFG_BASHRC_TARGET="root"
        else
            CFG_BASHRC_TARGET="all"
        fi
    else
        CFG_BASHRC_TARGET="root"
    fi

    # 6. Zsh
    if [[ -z "$CFG_INSTALL_ZSH" ]]; then
        read -rp "🐚 安装 Zsh? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_ZSH="true" || CFG_INSTALL_ZSH="false"
        if [[ "$CFG_INSTALL_ZSH" == "true" && -z "$CFG_ZSH_DEFAULT" ]]; then
            read -rp "   -> 设为默认Shell? (y/N): " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] && CFG_ZSH_DEFAULT="true" || CFG_ZSH_DEFAULT="false"
        fi
    fi

    # 7. Fail2Ban
    if [[ -z "$CFG_INSTALL_FAIL2BAN" ]]; then
        read -rp "🛡️ 安装 Fail2Ban? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_FAIL2BAN="true" || CFG_INSTALL_FAIL2BAN="false"
    fi

    # 7.1 PVE 专用配置 (仅在安装 Fail2Ban 时询问)
    if [[ "$CFG_INSTALL_FAIL2BAN" == "true" ]]; then
        if [[ "$IS_PVE" == "true" ]]; then
            echo -e "\n${C_CYAN}检测到 Proxmox VE 环境${C_RESET}"
            read -rp "🔧 配置 PVE 专用 SSH 过滤规则? (Y/n): " -n 1 -r; echo
            [[ $REPLY =~ ^[Nn]$ ]] && CFG_FAIL2BAN_PVE="false" || CFG_FAIL2BAN_PVE="true"
        else
            CFG_FAIL2BAN_PVE="false"
        fi

        # 7.2 Recidive 惯犯追踪
        read -rp "🔁 启用 Recidive 惯犯追踪? (Y/n): " -n 1 -r; echo
        [[ $REPLY =~ ^[Nn]$ ]] && CFG_FAIL2BAN_RECIDIVE="false" || CFG_FAIL2BAN_RECIDIVE="true"

        if [[ "$CFG_FAIL2BAN_RECIDIVE" == "true" ]]; then
            read -rp "   -> 惯犯封禁时间-天 (默认7): " v
            [[ -z "$v" || "$v" -le 0 ]] && CFG_RECIDIVE_BANTIME="604800" || CFG_RECIDIVE_BANTIME=$((v * 86400))
        fi
    fi

    # 8. Docker
    if [[ -z "$CFG_INSTALL_DOCKER" ]]; then
        read -rp "🐳 安装 Docker? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_DOCKER="true" || CFG_INSTALL_DOCKER="false"
    fi
    if [[ "$CFG_INSTALL_DOCKER" == "true" && -z "$CFG_DOCKER_MIRROR" ]]; then
        read -rp "   -> 配置镜像加速? (URL, 留空跳过): " CFG_DOCKER_MIRROR
    fi

    # 9. SSH Pubkey
    if [[ -z "$CFG_SSH_PUBKEY" ]]; then
        read -rp "🔑 导入 SSH 公钥? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && { echo "👇 粘贴公钥:"; read -r CFG_SSH_PUBKEY; }
        read -rp " 是否开启密码登录? 默认no (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] && CFG_SSH_PASSWDLOGIN="yes" || CFG_SSH_PASSWDLOGIN="no"
    fi

    echo -e "\n🚀 配置收集完成，开始执行..."
}

# --- [4] 执行模块 ---

task_base() {
    log_info "[1/7] 基础环境..."
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
    log_info "[2/7] SSH 配置..."
    [[ "$OS_ID" =~ (debian|ubuntu|rhel|centos|almalinux|rocky) ]] && install_pkgs openssh-server

    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    if [[ -n "$CFG_SSH_PUBKEY" ]]; then
        if ! grep -Fq "$CFG_SSH_PUBKEY" ~/.ssh/authorized_keys; then
            echo "$CFG_SSH_PUBKEY" >> ~/.ssh/authorized_keys
        fi
        chmod 600 ~/.ssh/authorized_keys
    fi

    local ssh_conf="/etc/ssh/sshd_config"
    cp "$ssh_conf" "${ssh_conf}.bak.$(date +%F_%H%M%S)"
    sed -i -E 's/^#?Port [0-9]+/#&/' "$ssh_conf"

    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" "$ssh_conf"; then
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$ssh_conf"
    fi

    cat > /etc/ssh/sshd_config.d/99-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication $CFG_SSH_PASSWDLOGIN
PermitRootLogin yes
EOF

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
    log_info "[3/7] Swap..."
    fallocate -l "${CFG_SWAP_SIZE}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1G count="$CFG_SWAP_SIZE"
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
}

task_shell() {
    log_info "[4/7] Shell 环境..."

    # Zsh
    if [[ "$CFG_INSTALL_ZSH" == "true" ]]; then
        install_pkgs zsh
        [[ "$CFG_ZSH_DEFAULT" == "true" ]] && chsh -s "$(which zsh)" root

        if [[ ! -d "~/.oh-my-zsh" ]]; then
            if [[ "$CFG_INTERNATIONAL_NETWORK" == "true" ]]; then
                 sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
            else
                 sh -c "$(curl -fsSL https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh)" "" --unattended \
                 REMOTE=https://gitee.com/mirrors/oh-my-zsh.git || true
            fi
        fi
    fi

    # Neovim
    if ! command -v nvim >/dev/null; then
        log_info "安装 Neovim (Binary)..."
        local arch; arch=$(uname -m)
        local nvim_file="nvim-linux-x86_64.tar.gz"
        local nvim_dir="nvim-linux-x86_64"

        if [[ "$arch" == "aarch64" ]]; then
            nvim_file="nvim-linux-arm64.tar.gz"; nvim_dir="nvim-linux-arm64"
        fi

        local nvim_bin_url=""
        local lazyvim_git_url=""

        if [[ "$CFG_INTERNATIONAL_NETWORK" == "true" ]]; then
            nvim_bin_url="https://github.com/neovim/neovim/releases/latest/download/$nvim_file"
            lazyvim_git_url="https://github.com/LazyVim/starter"
        else
            nvim_bin_url="https://gitee.com/luna_sama/shell-scripts/releases/download/nvim/$nvim_file"
            lazyvim_git_url="https://gitee.com/luna_sama/starter.git"
        fi

        cd /tmp
        if curl -fL -o "$nvim_file" "$nvim_bin_url"; then
            rm -rf "/opt/$nvim_dir"
            if tar -C /opt -xzf "$nvim_file"; then
                ln -sf "/opt/$nvim_dir/bin/nvim" /usr/local/bin/nvim
                log_success "Neovim 安装完毕"
            fi
            rm -f "$nvim_file"
        fi

        if [[ -x "/usr/local/bin/nvim" && ! -d ~/.config/nvim ]]; then
            git clone --depth=1 "$lazyvim_git_url" ~/.config/nvim || true && NVIM_INIT=1
        fi
    fi
}

task_docker() {
    [[ "$CFG_INSTALL_DOCKER" != "true" ]] && return
    log_info "[5/7] Docker..."

    if ! command -v docker >/dev/null; then
        local docker_ver="28.5.2"
        if [[ "$CFG_INTERNATIONAL_NETWORK" == "true" ]]; then
            curl -fsSL https://get.docker.com/ | bash -s -- --version "$docker_ver"
        else
            curl -fsSL https://gitee.com/luna_sama/shell-scripts/raw/main/install-docker.sh | bash -s -- --version "$docker_ver"
        fi
    else
        log_warn "Docker 已存在，跳过安装"
    fi

    if [[ -n "$CFG_DOCKER_MIRROR" ]]; then
        mkdir -p /etc/docker
        local djson="/etc/docker/daemon.json"
        if [[ ! -f "$djson" ]]; then
            echo "{\"registry-mirrors\": [\"$CFG_DOCKER_MIRROR\"]}" > "$djson"
        elif command -v jq >/dev/null; then
            tmp=$(mktemp)
            jq --arg m "$CFG_DOCKER_MIRROR" '.["registry-mirrors"] += [$m] | .["registry-mirrors"] |= unique' "$djson" > "$tmp" && mv "$tmp" "$djson"
        fi
        systemctl daemon-reload; systemctl restart docker
    fi
}

# --- PVE 专用 SSH 过滤规则配置 ---
_configure_pve_filters() {
    log_info "配置 PVE 专用 SSH 过滤规则..."

    local filter_dir="/etc/fail2ban/filter.d"
    local jail_dir="/etc/fail2ban/jail.d"

    # 创建 PVE SSH 过滤器
    cat > "$filter_dir/pve-sshd.conf" <<EOF
[Definition]
failregex = ^.*authentication failure.*rhost=<HOST>
ignoreregex =
EOF

    # 配置 SSH 日志路径 - PVE 默认在 daemon.log
    local ssh_logpath="/var/log/ssh.log"
    [[ -f /var/log/daemon.log ]] && ssh_logpath="/var/log/daemon.log"

    # 创建 PVE SSH jail 配置
    cat > "$jail_dir/pve-sshd.local" <<EOF
[pve-sshd]
enabled = true
filter = pve-sshd
port = $CFG_SSH_PORT
logpath = $ssh_logpath
backend = auto
maxretry = 5
findtime = 18000
bantime = 86400
action = iptables-allports[name=pve-sshd]
EOF

    log_success "PVE SSH 过滤规则已配置"
}

# --- Recidive 惯犯追踪配置 ---
_configure_recidive() {
    log_info "配置 Recidive 惯犯追踪..."

    local jail_dir="/etc/fail2ban/jail.d"
    local ban_days=$((CFG_RECIDIVE_BANTIME / 86400))

    cat > "$jail_dir/recidive.local" <<EOF
[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
maxretry = 3
findtime = 86400
bantime = $CFG_RECIDIVE_BANTIME
action = iptables-allports[name=recidive]
EOF

    log_success "Recidive 已配置 (封禁时长: ${ban_days} 天)"
}

task_fail2ban() {
    [[ "$CFG_INSTALL_FAIL2BAN" != "true" ]] && return
    log_info "[6/7] Fail2Ban..."

    if [[ "$OS_ID" =~ (debian|ubuntu) ]]; then
        install_pkgs fail2ban rsyslog
        systemctl enable --now rsyslog 2>/dev/null || true
    else
        install_pkgs fail2ban
    fi

    local logpath="/var/log/ssh.log"
    [[ "$OS_ID" =~ (rhel|centos|almalinux) ]] && logpath="/var/log/secure"
    [[ ! -f "$logpath" ]] && touch "$logpath"

    # 基础 SSH jail 配置
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
filter = sshd
port = $CFG_SSH_PORT
logpath = $logpath
backend = auto
maxretry = 5
findtime = 18000
bantime = 86400
EOF

    # PVE 专用配置
    if [[ "$CFG_FAIL2BAN_PVE" == "true" ]]; then
        _configure_pve_filters
    fi

    # Recidive 配置
    if [[ "$CFG_FAIL2BAN_RECIDIVE" == "true" ]]; then
        _configure_recidive
    fi

    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl restart fail2ban
    log_success "Fail2Ban 服务已启动"
}

# --- [5] 个人环境配置 ---

# 内部函数：为指定用户配置 .bashrc
_config_user_bashrc() {
    local target_user="$1"
    local target_home="$2"

    log_info "正在配置用户环境: $target_user ($target_home)"

    local bashrc_url=""
    local alias_url=""

    if [[ "$CFG_INTERNATIONAL_NETWORK" == "true" ]]; then
        bashrc_url="https://raw.githubusercontent.com/Luna-same/shell-scripts/refs/heads/main/.bashrc"
        alias_url="https://raw.githubusercontent.com/cykerway/complete-alias/master/complete_alias"
    else
        bashrc_url="https://gitee.com/luna_sama/shell-scripts/raw/main/.bashrc"
        alias_url="https://gitee.com/luna_sama/shell-scripts/releases/download/completion-alias/complete_alias"
    fi

    # 清理旧配置
    rm -f "${target_home}/.bashrc"

    # 下载文件
    if curl -Lso "${target_home}/.bashrc" "$bashrc_url"; then
        log_success "[$target_user] .bashrc 下载成功"
    else
        log_warn "[$target_user] .bashrc 下载失败"
    fi

    if curl -Lso "${target_home}/complete_alias" "$alias_url"; then
        log_success "[$target_user] complete_alias 下载成功"
    else
        log_warn "[$target_user] complete_alias 下载失败"
    fi

    # 修正权限
    if [[ "$target_user" != "root" ]]; then
        chown "$target_user:$target_user" "${target_home}/.bashrc"
        chown "$target_user:$target_user" "${target_home}/complete_alias"
    fi
}

bash_pri() {
    log_info "[7/7] 个人环境配置..."

    # 1. 总是配置 Root
    _config_user_bashrc "root" "/root"

    # 2. 根据选项配置 UID 1000 用户
    if [[ "$CFG_BASHRC_TARGET" == "all" && -n "$TARGET_USER_1000" ]]; then
        _config_user_bashrc "$TARGET_USER_1000" "/home/$TARGET_USER_1000"
    elif [[ -n "$TARGET_USER_1000" ]]; then
        log_info "跳过配置用户 $TARGET_USER_1000 的 .bashrc (用户选择仅 Root)"
    fi

    # 3. 设置系统级默认编辑器 (Vim)
    if update-alternatives --list editor 2>/dev/null | grep -q "vim.basic"; then
        update-alternatives --set editor /usr/bin/vim.basic 2>/dev/null || true
    fi

    # 4. 配置 Sudo 免密 (独立于 .bashrc 选项，只要有用户通常都建议配置)
    if [[ -n "$TARGET_USER_1000" ]]; then
        local sudo_group="sudo"
        [[ "$OS_ID" =~ (centos|rhel|almalinux|rocky|fedora|anolis) ]] && sudo_group="wheel"

        usermod -aG "$sudo_group" "$TARGET_USER_1000"

        local sudo_config="/etc/sudoers.d/99-${TARGET_USER_1000}-nopasswd"
        echo "$TARGET_USER_1000 ALL=(ALL) NOPASSWD: ALL" > "$sudo_config"
        chmod 0440 "$sudo_config"

        if visudo -c -f "$sudo_config" >/dev/null; then
            log_success "用户 $TARGET_USER_1000 已配置 Sudo 免密"
        else
            rm -f "$sudo_config"
            log_warn "Sudo 配置校验失败，已回滚"
        fi
    fi

    # 5. 全局动态颜色 (System-wide, 支持非登录 Shell)
    local global_bashrc=""

    # 根据发行版判断系统级 bashrc 位置
    if [[ "$OS_ID" =~ (debian|ubuntu|kali|armbian) ]]; then
        global_bashrc="/etc/bash.bashrc"
    elif [[ "$OS_ID" =~ (centos|rhel|fedora|almalinux|rocky|anolis) ]]; then
        global_bashrc="/etc/bashrc"
    elif [[ "$OS_ID" == "alpine" ]]; then
        global_bashrc="/etc/bash/bashrc"
    fi

    # 只有找到文件才执行注入
    if [[ -n "$global_bashrc" && -f "$global_bashrc" ]]; then
        if ! grep -q "AUTOMATED_PS1_COLOR" "$global_bashrc"; then
            cat >> "$global_bashrc" <<'EOF'

# --- AUTOMATED_PS1_COLOR START ---
# 仅在交互式 Bash 中生效
if [ -n "$BASH_VERSION" ] && [[ $- == *i* ]]; then
    if [ "$EUID" -eq 0 ]; then
        # Root: 紫色用户主机名 + 蓝色路径
        PS1='${debian_chroot:+($debian_chroot)}\[\033[01;35m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    else
        # 普通用户: 绿色用户主机名 + 蓝色路径
        PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    fi
fi
# --- AUTOMATED_PS1_COLOR END ---
EOF
            log_success "全局 Shell 颜色已注入到 $global_bashrc"
        else
            log_warn "全局颜色配置已存在于 $global_bashrc，跳过"
        fi
    else
        log_error "未找到系统级 bashrc 文件，无法配置全局颜色"
    fi
}

main() {
    check_root
    detect_env   # 包含 OS 检测、网络检测、用户检测、PVE检测
    collect_info # 包含所有交互问答

    task_base
    task_ssh
    task_swap
    task_shell
    task_docker
    task_fail2ban

    bash_pri

    echo -e "\n${C_GREEN}✅ 初始化完成!${C_RESET}"
    echo "⚠️  SSH 端口: $CFG_SSH_PORT (请检查防火墙)"
    echo "个人配置文件已更新，请执行source .bashrc"
    [[ "${NVIM_INIT:-0}" == "1" ]] && echo "lazyvim 下载完成，请使用vim或nvim命令加载"
    [[ "$CFG_INSTALL_ZSH" == "true" ]] && echo "🔄 重新登录生效。"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

CFG_HOSTNAME=""
CFG_SSH_PORT=""
CFG_INSTALL_ZSH=""       
CFG_ZSH_DEFAULT=""       
CFG_INSTALL_FAIL2BAN=""  
CFG_INSTALL_DOCKER=""    
CFG_SWAP_SIZE=""         
CFG_SSH_PUBKEY=""
CFG_GIT_NAME=""
CFG_GIT_EMAIL=""

STATUS_NVIM="未安装"
STATUS_DOCKER="未安装"
STATUS_ZSH="未安装"
STATUS_FAIL2BAN="未安装"


# 2. 系统检测

[[ ${EUID} -ne 0 ]] && { echo "❌ 必须以 root 运行"; exit 1; }

echo "=== 🔍 检测系统环境 ==="
CMD_INSTALL=""
CMD_UPDATE=""
SSH_PKG=""
OS_TYPE=""

if [[ -f /etc/os-release ]]; then . /etc/os-release; else echo "❌ 无 os-release"; exit 1; fi

case "$ID" in
  debian|ubuntu|kali|armbian)
    OS_TYPE="debian"
    CMD_UPDATE="apt-get update"
    CMD_INSTALL="apt-get install -y"
    SSH_PKG="openssh-server"
    export DEBIAN_FRONTEND=noninteractive
    ;;
  centos|rhel|fedora|almalinux|rocky|anolis)
    OS_TYPE="rhel"
    SSH_PKG="openssh-server"
    if command -v dnf >/dev/null; then
      CMD_UPDATE="dnf makecache"
      CMD_INSTALL="dnf install -y"
    else
      CMD_UPDATE="yum makecache"
      CMD_INSTALL="yum install -y"
    fi
    ;;
  alpine)
    OS_TYPE="alpine"
    CMD_UPDATE="apk update"
    CMD_INSTALL="apk add"
    SSH_PKG="openssh"
    ;;
  *) echo "❌ 不支持: $ID"; exit 1 ;;
esac

echo "✅ 系统: $PRETTY_NAME ($OS_TYPE)"
echo "✅ 策略: 依赖对齐 (不强制升级内核)"

USE_SYSTEMD="false"
[[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1 && USE_SYSTEMD="true"
SSH_SERVICE="sshd"
[[ "$OS_TYPE" == "debian" ]] && SSH_SERVICE="ssh"
svc_restart() { local s="$1"; if [[ "$USE_SYSTEMD" == "true" ]]; then systemctl restart "$s"; elif command -v service >/dev/null 2>&1; then service "$s" restart; elif command -v rc-service >/dev/null 2>&1; then rc-service "$s" restart; fi; }
svc_enable() { local s="$1"; if [[ "$USE_SYSTEMD" == "true" ]]; then systemctl enable "$s" --now >/dev/null 2>&1 || true; elif command -v rc-update >/dev/null 2>&1; then rc-update add "$s" default >/dev/null 2>&1 || true; fi; }

# ==============================================================================
# 3. 交互逻辑
# 修复：在 set -e 模式下，必须使用 if 结构，
# 否则 [[ -z "$VAR" ]] 返回 false 时会导致脚本立即退出。

# 3.1 主机名
if [[ -z "$CFG_HOSTNAME" ]]; then
    read -p "🖥️  主机名 (留空跳过): " v
    CFG_HOSTNAME="$v"
fi

# 3.2 SSH端口
if [[ -z "$CFG_SSH_PORT" ]]; then
    read -p "🔒 SSH端口 (默认22): " v
    CFG_SSH_PORT="${v:-22}"
fi

# 3.3 Swap
if [[ -z "$CFG_SWAP_SIZE" ]]; then
  if swapon --summary | grep -q .; then
    read -p "💾 已有Swap，是否调整? (GB，留空跳过): " CFG_SWAP_SIZE
  else
    read -p "💾 创建Swap? (GB，留空跳过): " CFG_SWAP_SIZE
  fi
fi

# 3.4 Git
if [[ -z "$CFG_GIT_NAME" ]]; then
    echo "🔧 Git配置 (留空跳过):"
    read -p "   -> Name: " CFG_GIT_NAME
    if [[ -n "$CFG_GIT_NAME" ]]; then
        read -p "   -> Email: " CFG_GIT_EMAIL
    fi
fi

# 3.5 Zsh
if [[ -z "$CFG_INSTALL_ZSH" ]]; then
  read -p "🐚 安装 Zsh? (y/N): " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_ZSH="true" || CFG_INSTALL_ZSH="false"
  if [[ "$CFG_INSTALL_ZSH" == "true" && -z "$CFG_ZSH_DEFAULT" ]]; then
    read -p "   -> 设为默认Shell? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && CFG_ZSH_DEFAULT="true" || CFG_ZSH_DEFAULT="false"
  fi
fi

# 3.6 Fail2Ban
if [[ -z "$CFG_INSTALL_FAIL2BAN" ]]; then
  read -p "🛡️ 安装 Fail2Ban? (y/N): " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_FAIL2BAN="true" || CFG_INSTALL_FAIL2BAN="false"
fi

# 3.7 Docker
if [[ -z "$CFG_INSTALL_DOCKER" ]]; then
  read -p "🐳 安装 Docker? (y/N): " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_DOCKER="true" || CFG_INSTALL_DOCKER="false"
fi

# 3.8 SSH Key
if [[ -z "$CFG_SSH_PUBKEY" ]]; then
  read -p "🔑 导入 SSH 公钥? (y/N): " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] && { echo "👇 粘贴公钥:"; read -r CFG_SSH_PUBKEY; }
fi

# ==============================================================================
# 4. 执行安装
# ==============================================================================
echo -e "\n🚀 开始执行任务..."

# 4.0 RHEL Fix
[[ "$OS_TYPE" == "rhel" && -f /etc/yum.repos.d/adoptium.repo ]] && mv /etc/yum.repos.d/adoptium.repo /etc/yum.repos.d/adoptium.repo.bak

# 4.1 安装基础依赖 + 对齐 SSH 版本 (核心修改)
echo "--> [1/6] 更新源并同步基础软件..."
$CMD_UPDATE || echo "⚠️ 源更新轻微报错，尝试继续..."

# RHEL EPEL
[[ "$OS_TYPE" == "rhel" ]] && ! rpm -q epel-release >/dev/null 2>&1 && $CMD_INSTALL epel-release

# 🚨 核心逻辑: 
if [[ "$OS_TYPE" == "debian" ]]; then
    if apt-get install -y --only-upgrade curl git tar tree htop $SSH_PKG || apt-get install -y curl git tar tree htop $SSH_PKG; then
        echo "   -> 基础软件安装及 SSH 依赖对齐完成"
    else
        echo "❌ 基础软件安装失败，脚本退出以保护环境。"
        exit 1
    fi
else
    if $CMD_INSTALL curl git tar tree htop $SSH_PKG; then
        echo "   -> 基础软件安装及 SSH 依赖对齐完成"
    else
        echo "❌ 基础软件安装失败，脚本退出以保护环境。"
        exit 1
    fi
fi

# 4.2 网络检测 (Curl已就绪)
CFG_USE_ALIYUN="false"
if [[ "$CFG_INSTALL_DOCKER" == "true" ]]; then
  echo "🌐 检测 Docker 网络..."
  if curl -I -s --connect-timeout 3 --max-time 5 https://www.google.com >/dev/null; then
    echo "   -> 🚀 国际网络畅通"
  else
    echo "   -> 🐢 国际网络受限，将使用阿里云源"
    CFG_USE_ALIYUN="true"
  fi
fi

# 4.3 Fail2Ban
if [[ "$CFG_INSTALL_FAIL2BAN" == "true" ]]; then
  echo "--> [2/6] 安装 Fail2Ban..."
  $CMD_INSTALL fail2ban && STATUS_FAIL2BAN="已安装" || STATUS_FAIL2BAN="失败"
fi

# 4.4 Git Config
[[ -n "$CFG_GIT_NAME" ]] && git config --global user.name "$CFG_GIT_NAME"
[[ -n "$CFG_GIT_EMAIL" ]] && git config --global user.email "$CFG_GIT_EMAIL"
git config --global color.ui true

# 4.5 Hostname
[[ -n "$CFG_HOSTNAME" ]] && { if command -v hostnamectl >/dev/null 2>&1 && [[ "$USE_SYSTEMD" == "true" ]]; then hostnamectl set-hostname "$CFG_HOSTNAME"; else hostname "$CFG_HOSTNAME"; fi; }

# 4.6 SSH Config
echo "--> [3/6] 配置 SSH..."
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
  SSH_CONFIG_BAK="${SSH_CONFIG}.bak.$(date +%s)"
  cp "$SSH_CONFIG" "$SSH_CONFIG_BAK"
  mkdir -p /etc/ssh/sshd_config.d
  grep -q '^Include ' "$SSH_CONFIG" || echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSH_CONFIG"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [[ -n "$CFG_SSH_PUBKEY" ]]; then
    touch /root/.ssh/authorized_keys
    grep -qxF "$CFG_SSH_PUBKEY" /root/.ssh/authorized_keys || echo "$CFG_SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    cat > /etc/ssh/sshd_config.d/host-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
  else
    cat > /etc/ssh/sshd_config.d/host-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin yes
EOF
  fi
  if [[ "$OS_TYPE" == "rhel" ]] && command -v restorecon >/dev/null 2>&1; then
    restorecon -R /root/.ssh >/dev/null 2>&1 || true
  fi
  if sshd -t; then
    svc_restart "$SSH_SERVICE"
    echo "   -> SSH 服务已重启 (Port: $CFG_SSH_PORT)"
    if [[ "$STATUS_FAIL2BAN" == "已安装" ]]; then
        mkdir -p /etc/fail2ban/jail.d
        cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $CFG_SSH_PORT
maxretry = 3
bantime = 1h
EOF
        svc_enable "fail2ban"
        svc_restart "fail2ban"
    fi
  else
    echo "⚠️ SSH 配置校验失败！已回滚。"
    cp "$SSH_CONFIG_BAK" "$SSH_CONFIG"
  fi
fi

# 4.7 Swap
if [[ "$CFG_SWAP_SIZE" =~ ^[0-9]+$ ]] && (( CFG_SWAP_SIZE > 0 )); then
  echo "--> [4/6] 配置 Swap (${CFG_SWAP_SIZE}GB)..."
  swapoff -a 2>/dev/null || true
  rm -f /swapfile
  if ! fallocate -l "${CFG_SWAP_SIZE}G" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1G count="$CFG_SWAP_SIZE" status=progress
  fi
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  sysctl vm.swappiness=10 >/dev/null
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
fi

# 4.8 BBR
echo "--> [5/6] 开启 BBR..."
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || modprobe tcp_bbr >/dev/null 2>&1; then
  if ! grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null
fi

# 4.9 Neovim
echo "--> [6/6] 安装 Neovim..."
SKIP_NEOVIM=false
[[ "$OS_TYPE" == "rhel" ]] && grep -E "release 7\." /etc/redhat-release >/dev/null 2>&1 && SKIP_NEOVIM=true

if [[ "$SKIP_NEOVIM" == "false" ]]; then
  ARCH=$(uname -m)
  case "$ARCH" in x86_64) NV_FILE="nvim-linux-x86_64.tar.gz" ;; aarch64) NV_FILE="nvim-linux-arm64.tar.gz" ;; *) NV_FILE="" ;; esac
  if [[ -n "$NV_FILE" ]]; then
    cd /tmp
    if curl -LO --retry 3 --connect-timeout 15 "https://github.com/neovim/neovim/releases/latest/download/$NV_FILE"; then
      mkdir -p /opt
      tar -C /opt -xzf "$NV_FILE" || true
      NV_DIR=$(tar -tf "$NV_FILE" 2>/dev/null | head -1 | cut -f1 -d"/")
      if [[ -n "$NV_DIR" && -d "/opt/$NV_DIR" ]]; then
        for rc in "/root/.bashrc" "/root/.zshrc"; do
          [[ -f "$rc" ]] && ! grep -Fq "/opt/$NV_DIR/bin" "$rc" && echo "export PATH=\"\$PATH:/opt/$NV_DIR/bin\"" >> "$rc"
        done
        STATUS_NVIM="已安装"
        [[ ! -d /root/.config/nvim ]] && git clone https://github.com/LazyVim/starter /root/.config/nvim >/dev/null 2>&1
      else STATUS_NVIM="解压失败"; fi
    else STATUS_NVIM="下载失败"; fi
  else STATUS_NVIM="架构不支持"; fi
fi

# 4.10 Zsh
if [[ "$CFG_INSTALL_ZSH" == "true" ]]; then
  $CMD_INSTALL zsh && STATUS_ZSH="已安装" || STATUS_ZSH="失败"
  [[ ! -f /root/.zshrc ]] && touch /root/.zshrc
  if [[ "$STATUS_ZSH" == "已安装" && "$CFG_ZSH_DEFAULT" == "true" ]]; then
      chsh -s "$(which zsh)" root && STATUS_ZSH="已安装(默认)"
  fi
fi

# 4.11 Docker
  if [[ "$CFG_INSTALL_DOCKER" == "true" ]]; then
    MIRROR_ARG=""
    [[ "$CFG_USE_ALIYUN" == "true" ]] && MIRROR_ARG="--mirror Aliyun"
    if curl -fsSL https://get.docker.com | bash -s docker $MIRROR_ARG; then
        STATUS_DOCKER="已安装"
    else
        STATUS_DOCKER="失败"
    fi
  fi

# ==============================================================================
# 5. 总结
# ==============================================================================
echo ""
echo "=========================================="
echo "✅ 初始化任务完成"
echo "------------------------------------------"
echo "🖥️  Host : $PRETTY_NAME ($OS_TYPE)"
echo "🐚 Zsh  : $STATUS_ZSH"
echo "📝 Nvim : $STATUS_NVIM"
echo "🐳 Docker: $STATUS_DOCKER"
echo "🛡️ Fail2Ban: $STATUS_FAIL2BAN"
echo "------------------------------------------"
echo "💡 提示: 如果修改了 SSH 端口，请确保防火墙已放行。"
echo "=========================================="

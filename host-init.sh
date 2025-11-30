#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 🟢 1. 用户配置区 (CONFIGURATION)
#    - 填入值 = 自动模式 (脚本将直接使用该值)
#    - 留空 "" = 交互模式 (脚本运行时会询问，或者根据网络自动判断)
# ==============================================================================

# 主机名 (例如: "myserver")
CFG_HOSTNAME=""

# SSH 端口 (例如: "2222"，留空默认会问，回车默认为 22)
CFG_SSH_PORT=""

# 是否安装 Zsh (填 "true" 或 "false"，留空则询问)
CFG_INSTALL_ZSH=""

# Swap 大小 (单位 GB，填 "0" 代表不创建，留空则询问)
CFG_SWAP_SIZE=""

# SSH 公钥 (建议直接粘贴 "ssh-rsa AAAA..."；留空则询问是否粘贴)
CFG_SSH_PUBKEY=""

# 是否使用阿里云 Docker 源 (填 "true"/"false" 强制指定；留空则【自动检测网络】决定)
CFG_USE_ALIYUN=""

# ==============================================================================
# 🔵 2. 参数补全与智能检测
# ==============================================================================

[[ ${EUID} -ne 0 ]] && { echo "❌ 必须以 root 运行"; exit 1; }

echo "=== 初始化配置检查 ==="

# --- 2.1 主机名 ---
if [[ -n "$CFG_HOSTNAME" ]]; then
  echo "✅ 使用预设主机名: $CFG_HOSTNAME"
else
  read -p "🖥️  请输入主机名 (留空跳过): " input_val
  CFG_HOSTNAME="$input_val"
fi

# --- 2.2 SSH 端口 ---
if [[ -n "$CFG_SSH_PORT" ]]; then
  echo "✅ 使用预设 SSH 端口: $CFG_SSH_PORT"
else
  read -p "🔒 请输入 SSH 端口 (默认 22): " input_val
  CFG_SSH_PORT="${input_val:-22}"
fi

# --- 2.3 Swap 设置 ---
if [[ -n "$CFG_SWAP_SIZE" ]]; then
  echo "✅ 使用预设 Swap 大小: ${CFG_SWAP_SIZE}GB"
else
  if swapon --summary | grep -q .; then
    CUR=$(swapon --show --bytes | awk 'NR>1{sum+=$3} END{print int(sum/1024/1024/1024)}')
    echo "ℹ️  检测到已有 Swap: ${CUR}GB"
    read -p "💾 是否调整大小? 输入新大小(GB)，留空保持不变: " input_val
  else
    read -p "💾 检测到无 Swap，是否创建? 输入大小(GB)，留空跳过: " input_val
  fi
  CFG_SWAP_SIZE="$input_val"
fi

# --- 2.4 Zsh 安装 ---
if [[ -n "$CFG_INSTALL_ZSH" ]]; then
  echo "✅ Zsh 安装策略: $CFG_INSTALL_ZSH"
else
  read -p "🐚 是否安装 Zsh? (y/N): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] && CFG_INSTALL_ZSH="true" || CFG_INSTALL_ZSH="false"
fi

# --- 2.5 SSH 公钥 ---
if [[ -n "$CFG_SSH_PUBKEY" ]]; then
  echo "✅ 使用预设 SSH 公钥"
else
  read -p "🔑 是否导入 SSH 公钥? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "👇 请粘贴公钥内容 (粘贴后按回车):"
    read -r input_val
    CFG_SSH_PUBKEY="$input_val"
  fi
fi

# --- 2.6 Docker 源 (智能网络检测) ---
if [[ -n "$CFG_USE_ALIYUN" ]]; then
  echo "✅ 使用预设 Docker 镜像策略: $CFG_USE_ALIYUN"
else
  echo "🌐 正在检测网络环境以选择 Docker 源..."
  # 尝试连接 google.com，超时 3 秒
  if curl -I -s --connect-timeout 3 --max-time 5 https://www.google.com >/dev/null; then
    echo "   -> 🚀 国际网络连通性良好 (Google 可达)"
    echo "   -> 策略: 使用 Docker 官方源"
    CFG_USE_ALIYUN="false"
  else
    echo "   -> 🐢 国际网络连接超时/失败"
    echo "   -> 策略: 自动切换至阿里云镜像源"
    CFG_USE_ALIYUN="true"
  fi
fi

# ==============================================================================
# 🟠 3. 执行安装 (EXECUTION)
# ==============================================================================

echo -e "\n🚀 开始执行任务..."
export DEBIAN_FRONTEND=noninteractive

# --- 3.1 基础环境 ---
echo "--> 更新系统软件包..."
# 确保有 curl 用于后续操作
if ! command -v curl >/dev/null 2>&1; then
  apt update -y && apt install -y curl
fi
apt update -y
apt install -y git tar tree htop fail2ban || { echo "❌ 安装失败"; exit 1; }

# --- 3.2 设置主机名 ---
if [[ -n "$CFG_HOSTNAME" ]]; then
  hostnamectl set-hostname "$CFG_HOSTNAME"
fi

# --- 3.3 SSH 配置 ---
echo "--> 配置 SSH..."
if [[ -f /etc/ssh/sshd_config ]]; then
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  
  sed -i '/^Port /d' /etc/ssh/sshd_config
  sed -i '/^PubkeyAuthentication /d' /etc/ssh/sshd_config
  sed -i '/^PasswordAuthentication /d' /etc/ssh/sshd_config
  
  echo "Port $CFG_SSH_PORT" >> /etc/ssh/sshd_config
  echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

  mkdir -p /root/.ssh
  if [[ -n "$CFG_SSH_PUBKEY" ]]; then
    echo "$CFG_SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
  fi

  if sshd -t; then
    systemctl restart sshd || systemctl restart ssh
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $CFG_SSH_PORT
maxretry = 3
bantime = 1h
EOF
    systemctl restart fail2ban
  else
    echo "⚠️ SSH 配置错误，已回滚！"
    cp "/etc/ssh/sshd_config.bak.$(date +%s)" /etc/ssh/sshd_config
  fi
fi

# --- 3.4 Swap ---
if [[ -n "$CFG_SWAP_SIZE" && "$CFG_SWAP_SIZE" -gt 0 ]]; then
  echo "--> 设置 Swap: ${CFG_SWAP_SIZE}GB"
  swapoff -a 2>/dev/null || true
  rm -f /swapfile
  if ! fallocate -l "${CFG_SWAP_SIZE}G" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1G count="$CFG_SWAP_SIZE" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
  sysctl vm.swappiness=10 >/dev/null
fi

# --- 3.5 BBR ---
echo "--> 开启 BBR..."
if ! grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null
fi

# --- 3.6 Neovim (GitHub 依赖) ---
echo "--> 安装 Neovim..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  NV_FILE="nvim-linux-x86_64.tar.gz" ;;
  aarch64) NV_FILE="nvim-linux-arm64.tar.gz" ;;
  *)       NV_FILE="" ;;
esac

if [[ -n "$NV_FILE" ]]; then
  # 如果判定为国内机器，且没有配置代理，GitHub下载大概率会失败
  if [[ "$CFG_USE_ALIYUN" == "true" ]]; then
    echo "⚠️  检测到国内网络环境，从 GitHub 下载 Neovim 可能会超时..."
  fi

  cd /tmp
  # 增加重试机制
  if curl -LO --retry 3 --connect-timeout 10 "https://github.com/neovim/neovim/releases/latest/download/$NV_FILE"; then
    tar -C /opt -xzf "$NV_FILE"
    NV_DIR=$(tar -tf "$NV_FILE" | head -1 | cut -f1 -d"/")
    
    for rc in "/root/.bashrc" "/root/.zshrc"; do
      [[ -f "$rc" ]] && ! grep -q "neovim" "$rc" && echo "export PATH=\"\$PATH:/opt/$NV_DIR/bin\"" >> "$rc"
    done

    mkdir -p /root/.config
    [[ ! -d /root/.config/nvim ]] && git clone https://github.com/LazyVim/starter /root/.config/nvim
  else
    echo "❌ Neovim 下载失败 (网络连接超时)，跳过安装。"
  fi
else
  echo "⚠️ 架构 $ARCH 不支持自动安装 Neovim"
fi

# --- 3.7 Zsh ---
if [[ "$CFG_INSTALL_ZSH" == "true" ]]; then
  echo "--> 安装 Zsh..."
  apt install -y zsh
  [[ ! -f /root/.zshrc ]] && touch /root/.zshrc
fi

# --- 3.8 Docker (应用智能判断结果) ---
echo "--> 安装 Docker..."
if [[ "$CFG_USE_ALIYUN" == "true" ]]; then
  echo "   -> 应用源: 阿里云 (Aliyun Mirror)"
  curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
else
  echo "   -> 应用源: 官方源 (Official)"
  curl -fsSL https://get.docker.com | bash
fi

echo "=========================================="
echo "✅ 初始化完成！"
echo "SSH 端口: $CFG_SSH_PORT"
echo "请断开重连以应用环境。"
echo "=========================================="
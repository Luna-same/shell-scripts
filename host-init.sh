#!/usr/bin/env bash
set -euo pipefail

CFG_HOSTNAME=""
CFG_SSH_PORT=""
CFG_INSTALL_ZSH=""       
CFG_ZSH_DEFAULT=""       
CFG_INSTALL_FAIL2BAN=""  
CFG_INSTALL_DOCKER=""    
CFG_DOCKER_MIRROR=""
CFG_SWAP_SIZE=""         
CFG_SSH_PUBKEY=""
CFG_GIT_NAME=""
CFG_GIT_EMAIL=""

STATUS_NVIM="未安装"
STATUS_DOCKER="未安装"
STATUS_VIM="未安装"
STATUS_ZSH="未安装"
STATUS_FAIL2BAN="未安装"

REQUIRED_TOOLS="curl git tar tree htop"


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
    if [[ -z "$v" ]]; then
      CFG_SSH_PORT="22"
    elif [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )); then
      CFG_SSH_PORT="$v"
    else
      echo "   -> 端口无效，使用默认 22"
      CFG_SSH_PORT="22"
    fi
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
echo "--> [1/7] 更新源并同步基础软件..."
if [[ "$OS_TYPE" == "debian" ]]; then
  if grep -Eq '^\s*deb\s+cdrom:' /etc/apt/sources.list 2>/dev/null || grep -Rqs '^\s*deb\s+cdrom:' /etc/apt/sources.list.d 2>/dev/null; then
    sed -i -E 's/^\s*deb\s+cdrom:/# deb cdrom:/g' /etc/apt/sources.list 2>/dev/null || true
    if [[ -d /etc/apt/sources.list.d ]]; then
      for f in /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        sed -i -E 's/^\s*deb\s+cdrom:/# deb cdrom:/g' "$f" || true
      done
    fi
    echo "   -> 已禁用 CDROM 源"
  fi
fi
PKGS=""
for p in $REQUIRED_TOOLS; do
  command -v "$p" >/dev/null 2>&1 || PKGS="$PKGS $p"
done
command -v sshd >/dev/null 2>&1 || PKGS="$PKGS $SSH_PKG"
[[ "$OS_TYPE" == "rhel" ]] && ! rpm -q epel-release >/dev/null 2>&1 && $CMD_INSTALL epel-release
if [[ -n "$PKGS" ]]; then
  $CMD_UPDATE || echo "⚠️ 源更新轻微报错，尝试继续..."
  if [[ "$OS_TYPE" == "debian" ]]; then
      if apt-get install -y $PKGS; then
          echo "   -> 基础软件安装及 SSH 依赖对齐完成"
      else
          echo "❌ 基础软件安装失败，脚本退出以保护环境。"
          exit 1
      fi
  else
      if $CMD_INSTALL $PKGS; then
          echo "   -> 基础软件安装及 SSH 依赖对齐完成"
      else
          echo "❌ 基础软件安装失败，脚本退出以保护环境。"
          exit 1
      fi
  fi
else
  echo "   -> 基础软件已满足，无需下载"
fi

# 4.2 网络检测 (Curl已就绪)
CFG_USE_ALIYUN="false"
if [[ "$CFG_INSTALL_DOCKER" == "true" ]]; then
  echo "🌐 检测 Docker 网络..."
  if curl -fsI --connect-timeout 3 --max-time 5 https://get.docker.com >/dev/null; then
    echo "   -> 🚀 国际网络畅通"
  else
    echo "   -> 🐢 国际网络受限，将使用阿里云源"
    CFG_USE_ALIYUN="true"
  fi
fi

# 4.3 Fail2Ban
if [[ "$CFG_INSTALL_FAIL2BAN" == "true" ]]; then
  echo "--> [2/7] 安装 Fail2Ban..."
  if command -v fail2ban-server >/dev/null 2>&1; then
    STATUS_FAIL2BAN="已安装"
  else
    $CMD_INSTALL fail2ban && STATUS_FAIL2BAN="已安装" || STATUS_FAIL2BAN="失败"
  fi
fi

# 4.4 Git Config
[[ -n "$CFG_GIT_NAME" ]] && git config --global user.name "$CFG_GIT_NAME"
[[ -n "$CFG_GIT_EMAIL" ]] && git config --global user.email "$CFG_GIT_EMAIL"
git config --global color.ui true

# 4.5 Hostname
[[ -n "$CFG_HOSTNAME" ]] && { if command -v hostnamectl >/dev/null 2>&1 && [[ "$USE_SYSTEMD" == "true" ]]; then hostnamectl set-hostname "$CFG_HOSTNAME"; else hostname "$CFG_HOSTNAME"; fi; }

# 4.6 SSH Config
echo "--> [3/7] 配置 SSH..."
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
  SSH_CONFIG_BAK="${SSH_CONFIG}.bak.$(date +%s)"
  cp "$SSH_CONFIG" "$SSH_CONFIG_BAK"
  mkdir -p /etc/ssh/sshd_config.d
  HAS_INCLUDE="false"
  APPENDED_INCLUDE="false"
  APPENDED_EXPLICIT="false"
  if grep -Fq 'Include /etc/ssh/sshd_config.d/*.conf' "$SSH_CONFIG"; then
    HAS_INCLUDE="true"
  else
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$SSH_CONFIG"
    APPENDED_INCLUDE="true"
  fi
  if ! grep -Fxq 'Include /etc/ssh/sshd_config.d/99-host-init.conf' "$SSH_CONFIG"; then
    echo "Include /etc/ssh/sshd_config.d/99-host-init.conf" >> "$SSH_CONFIG"
    APPENDED_EXPLICIT="true"
  fi
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [[ -n "$CFG_SSH_PUBKEY" ]]; then
    touch /root/.ssh/authorized_keys
    if ! grep -qxF "$CFG_SSH_PUBKEY" /root/.ssh/authorized_keys; then echo "$CFG_SSH_PUBKEY" >> /root/.ssh/authorized_keys; fi
    chmod 600 /root/.ssh/authorized_keys
    cat > /etc/ssh/sshd_config.d/99-host-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
LoginGraceTime 30s
MaxAuthTries 3
EOF
  else
    cat > /etc/ssh/sshd_config.d/99-host-init.conf <<EOF
Port $CFG_SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin yes
LoginGraceTime 30s
MaxAuthTries 3
EOF
  fi
  if [[ "$OS_TYPE" == "rhel" ]] && command -v restorecon >/dev/null 2>&1; then
    restorecon -R /root/.ssh >/dev/null 2>&1 || true
    restorecon -R /etc/ssh/sshd_config.d >/dev/null 2>&1 || true
  fi
  if command -v ssh-keygen >/dev/null 2>&1; then ssh-keygen -A >/dev/null 2>&1 || true; fi
  if sshd -t; then
    svc_restart "$SSH_SERVICE"
    svc_enable "$SSH_SERVICE"
    echo "   -> SSH 服务已重启 (Port: $CFG_SSH_PORT)"
    if [[ "$STATUS_FAIL2BAN" == "已安装" ]]; then
        mkdir -p /etc/fail2ban/jail.d
        if [[ ! -f /etc/fail2ban/jail.d/sshd.local ]]; then
          F2B_BACKEND=""
          F2B_LOGPATH=""
          if [[ "$USE_SYSTEMD" == "true" ]]; then
            F2B_BACKEND="systemd"
          else
            if [[ "$OS_TYPE" == "debian" ]]; then
              F2B_LOGPATH="/var/log/auth.log"
            elif [[ "$OS_TYPE" == "rhel" ]]; then
              F2B_LOGPATH="/var/log/secure"
            else
              F2B_LOGPATH="/var/log/auth.log"
            fi
          fi
          cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $CFG_SSH_PORT
maxretry = 8
bantime = 1h
EOF
          [[ -n "$F2B_BACKEND" ]] && echo "backend = $F2B_BACKEND" >> /etc/fail2ban/jail.d/sshd.local
          [[ -n "$F2B_LOGPATH" ]] && echo "logpath = $F2B_LOGPATH" >> /etc/fail2ban/jail.d/sshd.local
        fi
        svc_enable "fail2ban"
        svc_restart "fail2ban"
    fi
  else
    echo "⚠️ SSH 配置校验失败！已回滚。"
    cp "$SSH_CONFIG_BAK" "$SSH_CONFIG"
    rm -f /etc/ssh/sshd_config.d/99-host-init.conf
    if [[ "$APPENDED_INCLUDE" == "true" ]]; then
      sed -i '/^Include \/etc\/ssh\/sshd_config\.d\/\*.conf$/d' "$SSH_CONFIG"
    fi
    if [[ "$APPENDED_EXPLICIT" == "true" ]]; then
      sed -i '/^Include \/etc\/ssh\/sshd_config\.d\/99-host-init\.conf$/d' "$SSH_CONFIG"
    fi
  fi
fi

# 4.7 Swap
if [[ "$CFG_SWAP_SIZE" =~ ^[0-9]+$ ]] && (( CFG_SWAP_SIZE > 0 )); then
echo "--> [4/7] 配置 Swap (${CFG_SWAP_SIZE}GB)..."
  swapoff -a 2>/dev/null || true
  rm -f /swapfile
  if ! fallocate -l "${CFG_SWAP_SIZE}G" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1G count="$CFG_SWAP_SIZE" status=progress
  fi
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi
  sysctl vm.swappiness=10 >/dev/null
  if grep -Eq '^\s*vm\.swappiness\s*=' /etc/sysctl.conf; then
    sed -i -E 's/^\s*vm\.swappiness\s*=.*$/vm.swappiness=10/' /etc/sysctl.conf
  else
    echo "vm.swappiness=10" >> /etc/sysctl.conf
  fi
fi

# 4.8 BBR
echo "--> [5/7] 开启 BBR..."
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || modprobe tcp_bbr >/dev/null 2>&1; then
  if grep -Eq '^\s*net\.core\.default_qdisc\s*=' /etc/sysctl.conf; then
    sed -i -E 's/^\s*net\.core\.default_qdisc\s*=.*$/net.core.default_qdisc=fq/' /etc/sysctl.conf
  else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  fi
  if grep -Eq '^\s*net\.ipv4\.tcp_congestion_control\s*=' /etc/sysctl.conf; then
    sed -i -E 's/^\s*net\.ipv4\.tcp_congestion_control\s*=.*$/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
  else
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null
fi

# 4.9 Zsh
echo "--> [6/7] 安装 Zsh..."
if [[ "$CFG_INSTALL_ZSH" == "true" ]]; then
  if command -v zsh >/dev/null 2>&1; then
    STATUS_ZSH="已安装"
  else
    if [[ "$OS_TYPE" == "debian" ]]; then
      if apt-get install -y zsh; then STATUS_ZSH="已安装"; else STATUS_ZSH="失败"; fi
    elif [[ "$OS_TYPE" == "rhel" ]]; then
      if { command -v dnf >/dev/null 2>&1 && dnf install -y zsh; } || { command -v yum >/dev/null 2>&1 && yum install -y zsh; }; then STATUS_ZSH="已安装"; else STATUS_ZSH="失败"; fi
    elif [[ "$OS_TYPE" == "alpine" ]]; then
      if apk add zsh; then STATUS_ZSH="已安装"; else STATUS_ZSH="失败"; fi
    fi
  fi
  [[ ! -f /root/.zshrc ]] && touch /root/.zshrc
  if [[ "$STATUS_ZSH" == "已安装" && "$CFG_ZSH_DEFAULT" == "true" ]]; then
      if command -v zsh >/dev/null 2>&1; then
          ZSHELL="$(command -v zsh)"
          [[ -f /etc/shells ]] || touch /etc/shells
          grep -Fxq "$ZSHELL" /etc/shells || echo "$ZSHELL" >> /etc/shells
          CURRENT_SHELL="$(getent passwd root | cut -d: -f7 2>/dev/null || echo /bin/sh)"
          if [[ "$CURRENT_SHELL" != "$ZSHELL" && "${CURRENT_SHELL##*/}" != "zsh" ]]; then
            if command -v chsh >/dev/null 2>&1; then
                chsh -s "$ZSHELL" root && STATUS_ZSH="已安装(默认)"
            elif command -v usermod >/dev/null 2>&1; then
                usermod -s "$ZSHELL" root && STATUS_ZSH="已安装(默认)"
            fi
          else
            STATUS_ZSH="已安装(默认)"
          fi
      fi
  fi
fi

# 4.9 Neovim
echo "--> [7/7] 安装 Neovim..."
SKIP_NEOVIM=false
if [[ "$OS_TYPE" == "rhel" ]]; then
  RHEL_VER="$(rpm -E %rhel 2>/dev/null || true)"
  if [[ -n "$RHEL_VER" && "$RHEL_VER" -lt 8 ]]; then
    SKIP_NEOVIM=true
  elif grep -E "release 7\." /etc/redhat-release >/dev/null 2>&1; then
    SKIP_NEOVIM=true
  fi
fi

if [[ "$SKIP_NEOVIM" == "false" ]]; then
  if command -v nvim >/dev/null 2>&1; then
    STATUS_NVIM="已安装"
  else
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) NV_FILE="nvim-linux-x86_64.tar.gz" ;; aarch64) NV_FILE="nvim-linux-arm64.tar.gz" ;; *) NV_FILE="" ;; esac
    if [[ -n "$NV_FILE" ]]; then
      cd /tmp
      if curl -LO --retry 3 --connect-timeout 15 "https://github.com/neovim/neovim/releases/download/nightly/$NV_FILE"; then
        mkdir -p /opt
        if tar -C /opt/ -xzf "$NV_FILE"; then
          if NV_DIR=$(tar -tf "$NV_FILE" 2>/dev/null | head -1 | cut -f1 -d"/"); then
            if [[ -z "$NV_DIR" ]]; then
              NV_OPT_DIR="$(ls -1d /opt/nvim-* /opt/nvim-linux-* 2>/dev/null | head -1 || true)"
              [[ -n "$NV_OPT_DIR" ]] && NV_DIR="${NV_OPT_DIR#/opt/}"
            fi
            if [[ -n "$NV_DIR" && -d "/opt/$NV_DIR" ]]; then
              NV_BIN="/opt/$NV_DIR/bin/nvim"
              if [[ -x "$NV_BIN" ]]; then
                ln -sf "$NV_BIN" /usr/local/bin/nvim >/dev/null 2>&1 || ln -sf "$NV_BIN" /usr/bin/nvim >/dev/null 2>&1 || true
              fi
              if ! command -v nvim >/dev/null 2>&1; then
                for rc in "/root/.bashrc" "/root/.zshrc"; do
                  [[ -f "$rc" ]] || touch "$rc"
                  if ! grep -Fq "/opt/$NV_DIR/bin" "$rc"; then echo "export PATH=\"\$PATH:/opt/$NV_DIR/bin\"" >> "$rc"; fi
                done
              fi
              STATUS_NVIM="已安装"
              [[ -d /root/.config ]] || mkdir -p /root/.config
              if [[ ! -d /root/.config/nvim ]]; then
                echo "   -> 正在从 GitHub 克隆 LazyVim 配置..."
                # 尝试直连，去掉静默以便调试，或者保留静默但在失败时提示
                if ! git clone --depth=1 https://github.com/LazyVim/starter /root/.config/nvim >/dev/null 2>&1; then
                  echo "   -> ⚠️ 直连 GitHub 失败，尝试使用加速镜像..."
                  # 直接尝试镜像源，不再进行 curl 检测
                  if ! git clone --depth=1 https://gitclone.com/github.com/LazyVim/starter /root/.config/nvim >/dev/null 2>&1; then
                    echo "❌ LazyVim 配置下载彻底失败，请手动检查网络或 git 代理。"
                    # 此时可以选择让 STATUS_NVIM 变为 "配置失败"
                  else
                    echo "   -> ✅ 通过镜像源下载成功"
                  fi
                fi
              fi
            else
              STATUS_NVIM="解压失败"
            fi
          else
            STATUS_NVIM="解压失败"
          fi
        else
          STATUS_NVIM="解压失败"
        fi
      else
        STATUS_NVIM="下载失败"
      fi
    else
      STATUS_NVIM="架构不支持"
    fi
  fi
fi

echo "--> 安装 Vim(备用)..."
if command -v vim >/dev/null 2>&1; then
  STATUS_VIM="已安装"
else
  if [[ "$OS_TYPE" == "debian" ]]; then
    apt-get install -y vim && STATUS_VIM="已安装" || STATUS_VIM="失败"
  elif [[ "$OS_TYPE" == "rhel" ]]; then
    { command -v dnf >/dev/null 2>&1 && dnf install -y vim; } || { command -v yum >/dev/null 2>&1 && yum install -y vim; }
    if command -v vim >/dev/null 2>&1; then STATUS_VIM="已安装"; else STATUS_VIM="失败"; fi
  elif [[ "$OS_TYPE" == "alpine" ]]; then
    apk add vim && STATUS_VIM="已安装" || STATUS_VIM="失败"
  fi
fi

# alias 注入
for rc in "/root/.bashrc" "/root/.zshrc"; do
  [[ -f "$rc" ]] || touch "$rc"
  if ! grep -Eq '^alias\s+ll=' "$rc"; then
    {
      echo 'LS_OPTIONS="--color=auto -F"'
      echo "alias ls='ls --color=auto -F'"
      echo "alias ll='ls --color=auto -F -l'"
      echo "alias l='ls --color=auto -F -lA'"
      echo "alias rm='rm -i'"
      echo "alias cp='cp -i'"
      echo "alias mv='mv -i'"
    } >> "$rc"
  fi
done

if ! command -v nvim >/dev/null 2>&1; then
  NV_OPT_DIR="$(ls -1d /opt/nvim-* /opt/nvim-linux-* 2>/dev/null | head -1 || true)"
  if [[ -n "$NV_OPT_DIR" && -d "$NV_OPT_DIR/bin" ]]; then
    for rc in "/root/.bashrc" "/root/.zshrc"; do
      [[ -f "$rc" ]] || touch "$rc"
      if ! grep -Fq "$NV_OPT_DIR/bin" "$rc"; then echo "export PATH=\"\$PATH:$NV_OPT_DIR/bin\"" >> "$rc"; fi
    done
    if [[ -x "$NV_OPT_DIR/bin/nvim" ]]; then
      ln -sf "$NV_OPT_DIR/bin/nvim" /usr/local/bin/nvim >/dev/null 2>&1 || ln -sf "$NV_OPT_DIR/bin/nvim" /usr/bin/nvim >/dev/null 2>&1 || true
    fi
  fi
fi

 

# 4.11 Docker
if [[ "$CFG_INSTALL_DOCKER" == "true" ]]; then
  if command -v docker >/dev/null 2>&1; then
    STATUS_DOCKER="已安装"
  else
    DOCKER_URL="https://get.docker.com"
    [[ "$CFG_USE_ALIYUN" == "true" ]] && DOCKER_URL="https://gitee.com/luna_sama/shell-scripts/raw/main/install-docker.sh"
    if curl -fsSL "$DOCKER_URL" | bash; then
        STATUS_DOCKER="已安装"
    else
        STATUS_DOCKER="失败"
    fi
  fi
fi

if [[ "$CFG_INSTALL_DOCKER" == "true" && "$STATUS_DOCKER" == "已安装" ]]; then
  read -p "🚀 配置 Docker 镜像加速? (y/N): " -n 1 -r; echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "   -> 加速源地址 (默认 https://docker.1ms.run): " v
    CFG_DOCKER_MIRROR="${v:-https://docker.1ms.run}"
    DAEMON_JSON="/etc/docker/daemon.json"
    mkdir -p /etc/docker
    if command -v jq >/dev/null 2>&1 && [[ -f "$DAEMON_JSON" ]]; then
      tmp="$(cat "$DAEMON_JSON")"
      echo "$tmp" | jq --arg m "$CFG_DOCKER_MIRROR" '.["registry-mirrors"] = ((.["registry-mirrors"] // []) + [$m]) | .["registry-mirrors"] |= unique' > "$DAEMON_JSON.tmp" && mv "$DAEMON_JSON.tmp" "$DAEMON_JSON"
    else
      if [[ ! -f "$DAEMON_JSON" ]]; then
        cat > "$DAEMON_JSON" <<EOF
{
  "registry-mirrors": ["$CFG_DOCKER_MIRROR"]
}
EOF
      else
        if ! grep -Fq "$CFG_DOCKER_MIRROR" "$DAEMON_JSON"; then echo "⚠️ 未检测到 jq，未自动合并已存在的 daemon.json，请手动添加镜像源到 registry-mirrors"; fi
      fi
    fi
    svc_enable "docker"
    svc_restart "docker"
  fi
fi


echo ""
echo "=========================================="
echo "✅ 初始化任务完成"
echo "------------------------------------------"
echo "🖥️  Host : $PRETTY_NAME ($OS_TYPE)"
echo "🐚 Zsh  : $STATUS_ZSH"
echo "📝 Nvim : $STATUS_NVIM"
echo "✏️ Vim  : $STATUS_VIM"
echo "🐳 Docker: $STATUS_DOCKER"
echo "🛡️ Fail2Ban: $STATUS_FAIL2BAN"
F2B_SSH_SUMMARY="未安装"
if command -v fail2ban-client >/dev/null 2>&1; then
  if fail2ban-client status >/dev/null 2>&1; then
    JAILS="$(fail2ban-client status | sed -n 's/.*Jail list: //p')"
    if echo "$JAILS" | grep -qw sshd; then
      ST="$(fail2ban-client status sshd 2>/dev/null)"
      CUR="$(echo "$ST" | sed -n 's/.*Currently banned:\s*//p')"
      TOT="$(echo "$ST" | sed -n 's/.*Total banned:\s*//p')"
      F2B_SSH_SUMMARY="启用，当前封禁: ${CUR:-0}, 累计: ${TOT:-0}"
    else
      F2B_SSH_SUMMARY="未配置 sshd jail"
    fi
  else
    F2B_SSH_SUMMARY="服务未运行"
  fi
fi
echo "🔎 Fail2Ban[sshd]: $F2B_SSH_SUMMARY"
echo "------------------------------------------"
echo "💡 提示: SSH 端口已修改为 ${CFG_SSH_PORT:-22}，请确保防火墙已放行。"

# 收尾提示：根据当前默认 shell 提示刷新方式
DEFAULT_SHELL="$(getent passwd root | cut -d: -f7 2>/dev/null || echo /bin/sh)"
CUR_SHELL_NAME="${SHELL##*/}"
if [[ "${DEFAULT_SHELL##*/}" == "zsh" ]]; then
  if [[ "$CUR_SHELL_NAME" == "zsh" ]]; then
    echo "🔁 建议执行: source ~/.zshrc"
  else
    echo "🔁 建议执行: 重新连接以加载新配置"
  fi
else
  echo "🔁 建议执行: source ~/.bashrc 或重新连接以加载新配置"
fi

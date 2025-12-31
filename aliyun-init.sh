#!/bin/bash

# "=============================================================="


# 初始化阿里云ECS
# 以centos7.9内核
# 1.docker
# 2.jdk
# 3.tree、epel-release、等常用命令

# 若是有一行命令错误就退出
set -e

function jdk17-install {
    echo "开始安装 OpenJDK 17..."
    wget https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.16_8.tar.gz
    sudo mkdir -p /usr/local/java
    sudo tar -zxvf OpenJDK17U-jdk_x64_linux_hotspot_17.0.16_8.tar.gz -C /usr/local/java
cat > /etc/profile.d/java.sh << EOF
#!/bin/bash

export JAVA_HOME=/usr/local/java/jdk-17.0.16+8
# 将 Java 的 bin 目录添加到系统 PATH 变量的最前面
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

echo "OpenJDK 17 安装成功。请执行 'source /etc/profile.d/java.sh' 或重新登录使环境变量生效。"

}

function jdk8-install {
    echo "开始安装 OpenJDK 8..."
    yum install -y java-1.8.0-openjdk-devel
    echo "OpenJDK 8 安装成功。"
}
function docker-inatll {
    echo "开始安装 Docker..."
    sudo yum install -y yum-utils device-mapper-persistent-data lvm2
    sudo yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    sudo yum -y install docker-ce docker-ce-cli containerd.io
    mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": [
        "https://docker.1ms.run",
        "https://docker.xuanyuan.me"
    ]
}
EOF
        systemctl enable docker --now
    # 验证 Docker
    if docker run --rm hello-world &> /dev/null; then
        echo "Docker 安装并配置成功。"
    else
        echo "Docker 安装失败，请检查。"
        exit 1
    fi
}
# ===================================================
echo "回车以及输入名称表示确定 , 0表示否定"
read -p "您的新主机名称叫什么?  " hostname
read -p "是否安装docker?  " docker
read -p "是否安装jdk? 若是 , 选择8或17(回车默认安装jdk17): " jdk
read -p "是否修改ssh端口? 若是 , 请指定端口  " NEW_PORT

if [[ $hostname != "" ]]; then
    hostnamectl set-hostname "$hostname"
    echo "主机名已设置为: $hostname"
fi


echo "正在安装基础工具 (epel-release, tree)..."
yum -y install epel-release tree &> /dev/null
echo "基础工具安装完成。"

if [[ $docker == "" || $docker == "docker" ]]; then
    if command -v docker &> /dev/null; then
        echo "Docker 已安装，跳过安装步骤。"
    else
        docker-inatll
    fi
else
    echo "已跳过 Docker 安装。"
fi
# ==========================================================

if command -v java &> /dev/null; then
    echo "您已安装jdk , 版本是 $(java -version 2>&1 | head -n 1) , 将跳过jdk安装"
else
    if [[ $jdk == "8" ]]; then
        jdk8-install
    elif [[ $jdk == "17" || $jdk == "" ]]; then
        jdk17-install
    fi
fi
# ==========================================================
if [[ $NEW_PORT == "" ]]; then
    echo "跳过ssh端口设置"
else
    sudo sed -i -E "s/^#*\s*Port\s+.*/Port ${NEW_PORT}/" /etc/ssh/sshd_config
    cat /etc/ssh/sshd_config | grep Port
    echo ""
    echo ""
    systemctl restart sshd
    echo "ssh端口已更新完毕 , 请注意后续终端连接端口为${NEW_PORT}"
fi


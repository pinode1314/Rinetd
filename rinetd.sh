#!/bin/bash

export LANG=en_US.UTF-8

# 定义颜色变量
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 恢复默认颜色

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 权限运行此脚本 (sudo -i)${NC}"
    exit 1
fi

# 禁用 bash 历史记录，防止在服务器生成 .bash_history
ln -sf /dev/null ~/.bash_history
history -c

RINETD_CONF="/usr/local/etc/rinetd.conf"
SERVICE_NAME="rinetd"

# 卸载函数
uninstall_rinetd() {
    echo "--- 正在卸载 rinetd ---"
    systemctl stop $SERVICE_NAME 2>/dev/null
    systemctl disable $SERVICE_NAME 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    rm -f /usr/local/sbin/rinetd
    rm -rf $RINETD_CONF
    echo -e "${GREEN}✅ rinetd 已成功卸载！${NC}"
    exit 0
}

# 检查是否已经安装过
check_installed() {
    if [ -f /usr/local/sbin/rinetd ] || [ -f /etc/systemd/system/${SERVICE_NAME}.service ]; then
        return 0 # 已安装
    else
        return 1 # 未安装
    fi
}

# 显示当前转发规则（端口用绿色显示）
show_rules() {
    echo "========================================="
    echo "         当前已配置的转发规则"
    echo "========================================="
    if [ -f "$RINETD_CONF" ] && [ -s "$RINETD_CONF" ]; then
        # 读取文件并用 ANSI 颜色包裹端口号
        while read -r line; do
            # 过滤掉空行或注释行
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            
            # 提取行号和各字段 (0.0.0.0 ext_ip int_ip int_port)
            read -r ext_bind ext_port int_ip int_port <<< "$line"
            
            # 打印格式化文本，端口用 ${GREEN}...${NC}
            printf " [%d] 外部 %s:${GREEN}%s${NC}  -->  内部 %s:${GREEN}%s${NC}\n" "$((++i))" "$ext_bind" "$ext_port" "$int_ip" "$int_port"
        done < "$RINETD_CONF"
        unset i
    else
        echo -e "${YELLOW} (当前没有任何转发规则)${NC}"
    fi
    echo "========================================="
}

# 添加规则
add_rule() {
    echo ""
    echo "--- 添加转发规则 ---"
    read -p "请输入外网监听端口: " ext_port
    if ! [[ "$ext_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 端口输入错误！${NC}"
        return
    fi
    
    read -p "请输入内网目标 IP (默认 10.8.0.2): " int_ip
    int_ip=${int_ip:-10.8.0.2}
    
    read -p "请输入内网目标端口 (直接回车默认与外网相同): " int_port
    int_port=${int_port:-$ext_port}

    # 检查规则是否已存在
    if grep -q "0.0.0.0[[:space:]]\+$ext_port" "$RINETD_CONF" 2>/dev/null; then
        echo -e "${RED}⚠️ 警告：外网端口 $ext_port 的转发规则已存在！${NC}"
        return
    fi

    echo "0.0.0.0      $ext_port       $int_ip      $int_port" >> "$RINETD_CONF"
    echo -e "${GREEN}✅ 规则添加成功！正在重启 rinetd 服务...${NC}"
    systemctl restart $SERVICE_NAME
    echo -e "${GREEN}✅ rinetd 服务已重启完成。${NC}"
}

# 删除规则
delete_rule() {
    show_rules
    if [ ! -f "$RINETD_CONF" ] || [ ! -s "$RINETD_CONF" ]; then
        return
    fi
    
    read -p "请输入要删除的规则前面的编号 [数字]: " line_num
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 输入错误，请输入有效的数字编号！${NC}"
        return
    fi

    total_lines=$(wc -l < "$RINETD_CONF")
    if [ "$line_num" -gt "$total_lines" ] || [ "$line_num" -lt 1 ]; then
        echo -e "${RED}❌ 编号不存在！${NC}"
        return
    fi

    sed -i "${line_num}d" "$RINETD_CONF"
    echo -e "${GREEN}✅ 规则已删除！正在重启 rinetd 服务...${NC}"
    systemctl restart $SERVICE_NAME
    echo -e "${GREEN}✅ rinetd 服务已重启完成。${NC}"
}

# 批量修改所有规则的内网 IP
batch_update_ip() {
    echo ""
    echo "--- 批量修改内网 IP ---"
    if [ ! -f "$RINETD_CONF" ] || [ ! -s "$RINETD_CONF" ]; then
        echo -e "${YELLOW}当前没有任何转发规则可修改。${NC}"
        return
    fi

    show_rules
    read -p "请输入要替换的【旧内网 IP】(可留空跳过精确匹配，直接把所有规则的目标 IP 替换): " old_ip
    read -p "请输入要更换的新内网 IP: " new_ip

    if [ -z "$new_ip" ]; then
        echo -e "${RED}❌ 新内网 IP 不能为空！${NC}"
        return
    fi

    if [ -z "$old_ip" ]; then
        awk -v nip="$new_ip" '{ $3 = nip; print }' "$RINETD_CONF" > "${RINETD_CONF}.tmp" && mv "${RINETD_CONF}.tmp" "$RINETD_CONF"
    else
        awk -v oip="$old_ip" -v nip="$new_ip" '{ if ($3 == oip) $3 = nip; print }' "$RINETD_CONF" > "${RINETD_CONF}.tmp" && mv "${RINETD_CONF}.tmp" "$RINETD_CONF"
    fi

    echo -e "${GREEN}✅ 批量修改内网 IP 成功！正在重启 rinetd 服务...${NC}"
    systemctl restart $SERVICE_NAME
    echo -e "${GREEN}✅ rinetd 服务已重启完成，最新规则如下：${NC}"
    show_rules
}

# 交互主菜单
while true; do
    echo ""
    echo "========================================="
    echo "        Rinetd 端口转发管理脚本"
    echo "========================================="
    echo "1. 安装 rinetd (包含默认端口配置)"
    echo "2. 查看当前转发规则"
    echo "3. 添加转发规则"
    echo "4. 删除转发规则"
    echo "5. 批量修改内网 IP"
    echo "6. 卸载 rinetd"
    echo "0. 退出脚本"
    echo "========================================="
    read -p "请选择操作 [0-6]: " choice

    case $choice in
        1)
            if check_installed; then
                echo -e "${RED}⚠️ 检测到系统中已经安装过 rinetd！${NC}"
                echo -e "${RED}❌ 请先选择【6. 卸载 rinetd】将其卸载后，再进行全新安装。${NC}"
                continue
            fi

            echo "--- 1. 下载并解压 rinetd ---"
            if [ ! -d "rinetd-0.70" ]; then
                wget https://github.com/samhocevar/rinetd/releases/download/v0.70/rinetd-0.70.tar.gz
                tar xf rinetd-0.70.tar.gz
            fi
            cd rinetd-0.70

            echo "--- 2. 编译安装 ---"
            ./bootstrap
            ./configure
            make && make install
            cd ..

            echo "--- 3. 配置默认转发规则 ---"
            mkdir -p /usr/local/etc
            cat << 'CONFIG' > "$RINETD_CONF"
0.0.0.0      31400       10.8.0.2      31400
0.0.0.0      31401       10.8.0.2      31401
0.0.0.0      31402       10.8.0.2      31402
0.0.0.0      31403       10.8.0.2      31403
0.0.0.0      31404       10.8.0.2      31404
0.0.0.0      31405       10.8.0.2      31405
0.0.0.0      31406       10.8.0.2      31406
0.0.0.0      31407       10.8.0.2      31407
0.0.0.0      31408       10.8.0.2      31408
0.0.0.0      31409       10.8.0.2      31409
0.0.0.0      825         10.8.0.2      825
0.0.0.0      20200       10.8.0.2      20200
0.0.0.0      30300       10.8.0.2      30300
CONFIG

            echo "--- 4. 创建 Systemd 服务 ---"
            cat << 'SERVICE' > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=rinetd
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/sbin/rinetd -c /usr/local/etc/rinetd.conf
ExecReload=/bin/kill -SIGHUP $MAINPID
ExecStop=/bin/kill -SIGINT $MAINPID

[Install]
WantedBy=multi-user.target
SERVICE

            echo "--- 5. 启动服务并设置开机自启 ---"
            systemctl daemon-reload
            systemctl enable $SERVICE_NAME
            systemctl restart $SERVICE_NAME

            echo "-------------------------------------------"
            echo -e "${GREEN}✅ 安装完成！rinetd 已启动并设为开机自启。${NC}"
            echo "-------------------------------------------"
            ;;
        2)
            show_rules
            ;;
        3)
            if ! check_installed; then
                echo -e "${RED}❌ 错误：rinetd 尚未安装，请先选择 1 进行安装！${NC}"
                continue
            fi
            add_rule
            ;;
        4)
            if ! check_installed; then
                echo -e "${RED}❌ 错误：rinetd 尚未安装，请先选择 1 进行安装！${NC}"
                continue
            fi
            delete_rule
            ;;
        5)
            if ! check_installed; then
                echo -e "${RED}❌ 错误：rinetd 尚未安装，请先选择 1 进行安装！${NC}"
                continue
            fi
            batch_update_ip
            ;;
        6)
            uninstall_rinetd
            ;;
        0)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效的选择，请重新输入。${NC}"
            ;;
    esac
done

#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
DATE=$(date +%Y%m%d)

# 封装 rc.local 安全追加函数，避免 sed 删除错行
append_rc_local() {
    local cmd="$1"
    if [[ ! -f /etc/rc.local ]]; then
        cat > /etc/rc.local <<EOF
#!/bin/sh -e
# rc.local
# This script is executed at the end of each multiuser runlevel.
exit 0
EOF
        chmod +x /etc/rc.local
    fi
    # 删除原有的 exit 0，追加新命令后重新补上 exit 0
    sed -i '/^exit 0$/d' /etc/rc.local
    echo "$cmd" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local
}

install_ipip(){
    if ! lsmod | grep -q "ipip"; then
        modprobe ipip
    fi
    if ! command -v dig >/dev/null 2>&1; then
        apt-get install dnsutils -y >/dev/null 2>&1 || yum install dnsutils -y >/dev/null 2>&1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        apt install iptables -y >/dev/null 2>&1 || yum install iptables -y >/dev/null 2>&1
    fi

    echo -ne "请输入对端设备的ddns域名或者IP："
    read ddnsname
    read -p "请输入要创建的tun网卡名称：" tunname
    echo -ne "请输入tun网口的V-IP："
    read vip
    echo -ne "请输入对端的V-IP："
    read remotevip

    # 更精准地获取主网卡和本地IP
    netcardname=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    localip=$(ip -4 a show dev "$netcardname" | grep global | awk '{print $2}' | cut -d '/' -f 1 | head -1)

    # ping 增加 -W 2 超时，防止挂起
    remoteip=$(ping -4 -c 1 -W 2 "$ddnsname" | grep PING | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [[ -z "$remoteip" ]]; then
        remoteip=$ddnsname # 如果 ping 失败，假设输入的就是 IP
    fi

    rc_cmd="ip tunnel add $tunname mode ipip remote ${remoteip} local ${localip} ttl 64
ip addr add ${vip}/30 dev $tunname
ip link set $tunname up"

    append_rc_local "$rc_cmd"

    # 动态 IP 监控脚本
    if [[ ! "$ddnsname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cat >/root/change-tunnel-ip_${ddnsname}.sh <<EOF
#!/bin/bash
while true; do
    remoteip=\$(ping -4 -c 1 -W 2 "$ddnsname" | grep PING | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [[ "\$remoteip" != "" ]]; then
        echo "获取对端设备的IP为: \$remoteip"
        break
    fi
    sleep 2
done
oldip="\$(cat /root/.tunnel-ip.txt 2>/dev/null)"
netcardname=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
localip=\$(ip -4 a show dev "\$netcardname" | grep global | awk '{print \$2}' | cut -d '/' -f 1 | head -1)

if [[ "\$oldip" != "\$remoteip" ]]; then
    ip tunnel del $tunname
    wg-quick down wg0 2>/dev/null
    sed -i "/ip tunnel add $tunname mode ipip/c\ip tunnel add $tunname mode ipip remote \${remoteip} local \${localip} ttl 64" /etc/rc.local
    systemctl restart rc-local
fi
EOF
        echo "开始添加定时任务"
        bashsrc=$(command -v bash)
        # 清理旧的同名任务并添加新任务
        crontab -l 2>/dev/null | grep -v "change-tunnel-ip_${ddnsname}.sh" > /root/crontab_test 
        echo "*/2 * * * * ${bashsrc} /root/change-tunnel-ip_${ddnsname}.sh" >> /root/crontab_test 
        crontab /root/crontab_test 
        rm -f /root/crontab_test

        echo "-------------------------------------------------------"
        echo -e "设置定时任务成功，当前系统所有定时任务清单如下:\n$(crontab -l)"
        echo "-------------------------------------------------------"
    fi

    echo "${remoteip}" > /root/.tunnel-ip.txt
    ip tunnel add $tunname mode ipip remote ${remoteip} local $localip ttl 64
    ip addr add ${vip}/30 dev $tunname
    ip link set $tunname up
    ip route add ${remotevip}/32 dev $tunname scope link src ${vip}

    if ! iptables -t nat -L | grep -q "${remotevip}"; then
        iptables -t nat -A POSTROUTING -s ${remotevip} -j MASQUERADE
    fi
    if ! sysctl -p | grep -q "net.ipv4.ip_forward = 1"; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf
    fi

    chmod +x /etc/rc.local
    cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local
 
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
 
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rc-local
    echo "程序全部执行完毕，脚本退出。。"
    exit 0
}

install_ipipv6(){
    if ! lsmod | grep -q "tunnel6"; then
        modprobe ip6_tunnel
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        apt install iptables -y >/dev/null 2>&1 || yum install iptables -y >/dev/null 2>&1
    fi

    echo -ne "请输入对端设备的ddns域名或者IP："
    read ddnsname
    read -p "请输入要创建的tun网卡名称：" tunname
    echo -ne "请输入tun网口的V-IP："
    read vip
    echo -ne "请输入对端的V-IP："
    read remotevip

    netcardname=$(ip -6 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [[ -z "$netcardname" ]]; then
        netcardname=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    fi
    routerule=$(ip -6 route list | grep default | head -1 | awk '{print $1" "$2" "$3" "$4" "$5}')
    localip6=$(ip -6 a show dev "$netcardname" | grep 'scope global' | awk '{print $2}' | cut -d '/' -f 1 | head -1)

    remoteip=$(ping -6 -c 1 -W 2 "$ddnsname" | grep PING | grep -Eo '([0-9a-fA-F]{1,4}:)+[0-9a-fA-F]{1,4}' | head -n1)
    if [[ -z "$remoteip" ]]; then
        remoteip=$ddnsname
    fi

    # 动态 IP 监控脚本
    if [[ ! "$ddnsname" =~ ":" ]]; then
        cat >/root/change-tunnel-ipv6_${ddnsname}.sh <<EOF
#!/bin/bash
while true; do
    remoteip=\$(ping -6 -c 1 -W 2 "$ddnsname" | grep PING | grep -Eo '([0-9a-fA-F]{1,4}:)+[0-9a-fA-F]{1,4}' | head -n1)
    if [[ "\$remoteip" != "" ]]; then
        echo "获取对端设备的IP为: \$remoteip"
        break
    fi
    sleep 2
done
oldip="\$(cat /root/.tunnel-ipv6.txt 2>/dev/null)"
localip6=\$(ip -6 a | grep 'scope global' | awk '{print \$2}' | cut -d '/' -f 1 | head -1)

if [[ "\$oldip" != "\$remoteip" ]]; then
    ip tunnel del $tunname
    wg-quick down wg0 2>/dev/null
    sed -i "/ip link add name/c\ip link add name $tunname type ip6tnl local \${localip6} remote \${remoteip} mode any" /etc/rc.local
    systemctl restart rc-local
fi
EOF
        bashsrc=$(command -v bash)
        crontab -l 2>/dev/null | grep -v "change-tunnel-ipv6_${ddnsname}.sh" > /root/crontab_test 
        echo "*/2 * * * * ${bashsrc} /root/change-tunnel-ipv6_${ddnsname}.sh" >> /root/crontab_test 
        crontab /root/crontab_test 
        rm -f /root/crontab_test
    fi

    echo "${remoteip}" > /root/.tunnel-ipv6.txt
    read -p "当前机器是甲骨文吗？[Y/n]:" yn
    addtxt=""
    addtxt1=""
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        addtxt="dhclient -6 $netcardname"
        addtxt1="sleep 20s"
    fi

    rc_cmd="$addtxt1
$addtxt
ip link add name $tunname type ip6tnl local ${localip6} remote ${remoteip} mode any
ip addr add ${vip}/30 dev $tunname
ip link set $tunname up
ip -6 route add $routerule"

    append_rc_local "$rc_cmd"

    # 执行创建
    ip link add name $tunname type ip6tnl local ${localip6} remote ${remoteip} mode any
    ip addr add ${vip}/30 dev $tunname
    ip link set $tunname up
    ip -6 route add $routerule

    chmod +x /etc/rc.local
    cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
After=network.target
ConditionPathExists=/etc/rc.local
 
[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99
 
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rc-local

    if ! iptables -t nat -L | grep -q "${remotevip}"; then
        iptables -t nat -A POSTROUTING -s ${remotevip} -j MASQUERADE
    fi
    if ! sysctl -p | grep -q "net.ipv6.conf.all.forwarding=1"; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf
    fi

    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo -e "${red}提示:${plain}${yellow}你的机器是甲骨文，IPIPv6隧道生效,需要重启一次！${plain}"
    fi
    exit 0
}

install_wg(){
    apt-get update 
    apt-get install wireguard -y
    if [[ ! -f /etc/wireguard/privatekey ]]; then
        wg genkey | tee /etc/wireguard/privatekey | wg pubkey | tee /etc/wireguard/publickey
    fi
    localprivatekey=$(cat /etc/wireguard/privatekey)
    netcardname=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    read -p "请输入对端wg使用的V-ip地址:" revip
    read -p "请输入本机wg使用的v-ip地址:" localip1
    read -p "请输入ros端wg的公钥内容:" rospublickey
    read -p "请输入ros端wg调用的端口号:" wgport

    allowedip1=$(echo "$revip" | awk -F "." '{print $1"."$2"."$3}')
    
    filename="wg0"
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        read -p "请给本机wg配置文件取个名(英文):" filename
        if [[ -f "/etc/wireguard/${filename}.conf" ]]; then
            echo "⚠️  已存在同样名称的配置文件，程序退出，请重新执行程序。"
            exit 1
        fi
    fi

    read -p "请输入对端ipip隧道IP段(例如 192.168.2.1 只填写 192.168.2 即可)：" ipduan
    read -p "请输入对端ipip隧道的IP地址：" ipaddrremote

    cat > "/etc/wireguard/$filename.conf" <<EOF
[Interface]
ListenPort = $wgport
Address = $localip1/24
PostUp   = iptables -t nat -A POSTROUTING -o $netcardname -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $netcardname -j MASQUERADE
PrivateKey = $localprivatekey
	
[Peer]
PublicKey = $rospublickey
AllowedIPs = $ipduan.0/24,$allowedip1.0/24
Endpoint = ${ipaddrremote}:$wgport
PersistentKeepalive = 25
EOF

    chmod 600 "/etc/wireguard/$filename.conf"
    append_rc_local "wg-quick up $filename"
    wg-quick up "$filename"

    vpspublickey=$(cat /etc/wireguard/publickey)
    linstenport=$(grep "ListenPort" "/etc/wireguard/$filename.conf" | awk '{print $3}')
    vip=$(ip a | grep "scope global" | grep "/30" | awk '{print $2}' | cut -d '/' -f 1 | head -1)
    
    echo "    "
    echo -e "${green}------------------------------------------------------------${plain}"
    echo -e "${green}请在ROS的wireguard选项卡里边的Peers里添加配置，具体填写如下信息：${plain}"
    echo -e "Public key 填写：${yellow}${vpspublickey}${plain}"
    if [[ "$filename" == "wg0" && -n "$vip" ]]; then
        echo -e "Endpoint 填写：${yellow}${vip}${plain}"
    fi
    echo -e "Endpoint port 填写：${yellow}${linstenport}${plain}"
    echo -e "Allowed Address 填写：${green}0.0.0.0/0\n祝使用愉快。${plain}"
}

keep_alive(){
    read -p "请输入对端ipip隧道IP：" remoteip_1
    cat > /root/keepalive.sh <<EOF
#!/bin/bash
while true; do
    ping -4 -c 1 -W 2 "${remoteip_1}" >/dev/null 2>&1
    sleep 2
done
EOF
    append_rc_local "nohup bash /root/keepalive.sh >/dev/null 2>&1 &"
    nohup bash /root/keepalive.sh >/dev/null 2>&1 &
    echo -e "${yellow}IPIP隧道保活配置完成${plain}"
}

copyright(){
    clear
    echo -e "
${green}###########################################################${plain}
${green}#                                                         #${plain}
${green}#       IPIP tunnel隧道、Wireguard一键部署脚本            #${plain}
${green}#               Power By:翔翎                             #${plain}
${green}#                                                         #${plain}
${green}###########################################################${plain}"
}

main(){
    copyright
    echo -e "
${red}0.${plain}  退出脚本
${green}———————————————————————————————————————————————————————————${plain}
${green}1.${plain}  一键部署IPIP隧道
${green}2.${plain}  一键部署${red}IPIPv6${plain}隧道
${green}3.${plain}  一键部署wireguard
${green}4.${plain}  IPIP隧道保活
"
    echo -e "${yellow}请选择你要使用的功能${plain}"
    read -p "请输入数字 :" num   
    case "$num" in
        0) exit 0 ;;
        1) install_ipip ;;
        2) install_ipipv6 ;;
        3) install_wg ;;
        4) keep_alive ;;
        *)
            clear
            echo -e "${red}出现错误:请输入正确数字 ${plain}"
            sleep 2
            main
            ;;
    esac
}

main

#!/bin/bash

# 删除旧的配置文件
if [ -f "/etc/V2bX/config.json" ]; then
    echo "删除旧的配置文件 /etc/V2bX/config.json..."
    rm /etc/V2bX/config.json
fi

# 提示用户输入国家代码
echo "请输入要下载配置的国家代码："
echo "1. 澳大利亚（输入 au）"
echo "2. 香港（输入 hk）"
echo "3. 日本（输入 jp）"
echo "4. 台湾（输入 tw）"
echo "5. 英国（输入 uk）"
echo "6. 印度（输入 in）"
echo "7. 美国（输入 us）"
echo "8. 荷兰（输入 nl）"
echo "9. 新加坡（输入 sg）"
echo "10. 德国（输入 de）"
echo "11. 加拿大（输入 ca）"
echo "12. 随机（输入 sj）"
echo "13. 俄罗斯（输入 ru）"
echo "14. 韩国（输入 kr）"
read country

# 根据用户输入选择对应的配置文件和下载链接，并设置重命名的文件名为 config.json
case $country in
    "au")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/au-config.json"
        ;;
    "hk")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/hk-config.json"
        ;;
    "jp")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/jp-config.json"
        ;;
    "tw")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/tw-config.json"
        ;;
    "uk")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/uk-config.json"
        ;;
    "in")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/in-config.json"
        ;;   
    "us")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/us-config.json"
        ;;      
    "nl")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/nl-config.json"
        ;;   
    "sg")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/sg-config.json"
        ;;           
    "de")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/de-config.json"
        ;;      
    "ca")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/ca-config.json"
        ;;   
    "sj")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/sj-config.json"
        ;;          
    "ru")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/ru-config.json"
        ;;        
    "kr")
        config_file="config.json"
        download_link="https://github.com/w243420707/-/raw/main/kr-config.json"
        ;;           
    *)
        echo "无效的输入！"
        exit 1
        ;;
esac

# 下载配置文件并授予权限，并重命名为 config.json
echo "正在下载配置文件：$config_file"
wget -O /etc/V2bX/$config_file $download_link
chmod +x /etc/V2bX/$config_file

echo "配置文件 $config_file 下载完成并已授予执行权限。"

# 如果选择了 "sj"，执行额外的命令
if [ "$country" = "sj" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 i7Myi8HZdIHjPiwpLS
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-sj-l4ehusajhz18.sh -o hy-sj-l4ehusajhz18.sh
    chmod +x /root/hy-sj-l4ehusajhz18.sh
    sudo ./hy-sj-l4ehusajhz18.sh
fi
# 如果选择了 "us"，执行额外的命令
if [ "$country" = "us" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 0bEVM4CWCKlSI4OLxn
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-us-l4ehusajhz18.sh -o hy-us-l4ehusajhz18.sh
    chmod +x /root/hy-us-l4ehusajhz18.sh
    sudo ./hy-us-l4ehusajhz18.sh
fi
# 如果选择了 "au"，执行额外的命令
if [ "$country" = "au" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 rYchIL1LTRzjZbDyVw
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-au-l4ehusajhz18.sh -o hy-au-l4ehusajhz18.sh
    chmod +x /root/hy-au-l4ehusajhz18.sh
    sudo ./hy-au-l4ehusajhz18.sh
fi

# 如果选择了 "jp"，执行额外的命令
if [ "$country" = "jp" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 IThZ0uUDc377ErvXhF
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-jp-l4ehusajhz18.sh -o hy-jp-l4ehusajhz18.sh
    chmod +x /root/hy-jp-l4ehusajhz18.sh
    sudo ./hy-jp-l4ehusajhz18.sh
fi
# 如果选择了 "uk"，执行额外的命令
if [ "$country" = "uk" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 FALwm9kQyWL7u4k21F
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-uk-l4ehusajhz18.sh -o hy-uk-l4ehusajhz18.sh
    chmod +x /root/hy-uk-l4ehusajhz18.sh
    sudo ./hy-uk-l4ehusajhz18.sh
fi

# 如果选择了 "in"，执行额外的命令
if [ "$country" = "in" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 lA6WODakEauns1eiEv
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-in-l4ehusajhz18.sh -o hy-in-l4ehusajhz18.sh
    chmod +x /root/hy-in-l4ehusajhz18.sh
    sudo ./hy-in-l4ehusajhz18.sh
fi

# 如果选择了 "nl"，执行额外的命令
if [ "$country" = "nl" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 F9ASScSS4CXhrFMjUQ
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-nl-l4ehusajhz18.sh -o hy-nl-l4ehusajhz18.sh
    chmod +x /root/hy-nl-l4ehusajhz18.sh
    sudo ./hy-nl-l4ehusajhz18.sh
fi
# 如果选择了 "sg"，执行额外的命令
if [ "$country" = "sg" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 geKH2HPwo8NCviE6zJ
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-sg-l4ehusajhz18.sh -o hy-sg-l4ehusajhz18.sh
    chmod +x /root/hy-sg-l4ehusajhz18.sh
    sudo ./hy-sg-l4ehusajhz18.sh
fi


# 如果选择了 "de"，执行额外的命令
if [ "$country" = "de" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 Um5y77VNADb9d5Krc1
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-de-l4ehusajhz18.sh -o hy-de-l4ehusajhz18.sh
    chmod +x /root/hy-de-l4ehusajhz18.sh
    sudo ./hy-de-l4ehusajhz18.sh
fi

# 如果选择了 "ca"，执行额外的命令
if [ "$country" = "ca" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 ItTR1fQMAfgTTnPVCa
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-ca-l4ehusajhz18.sh -o hy-ca-l4ehusajhz18.sh
    chmod +x /root/hy-ca-l4ehusajhz18.sh
    sudo ./hy-ca-l4ehusajhz18.sh
fi
# 如果选择了 "ru"，执行额外的命令
if [ "$country" = "ru" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 9qtL6bglk0nw9KKcrk
    echo "DDNS修改IP..."
    curl -L https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-ru-l4ehusajhz18.sh -o hy-ru-l4ehusajhz18.sh
    chmod +x /root/hy-ru-l4ehusajhz18.sh
    sudo ./hy-ru-l4ehusajhz18.sh
fi
# 如果选择了 "kr"，执行额外的命令
if [ "$country" = "kr" ]; then
    echo "安装哪吒探针..."
    curl -L https://raw.githubusercontent.com/naiba/nezha/master/script/install.sh -o nezha.sh
    chmod +x nezha.sh
    sudo ./nezha.sh install_agent vpsip.flywhaler.com 5555 0ZWRM7OuXvD5U0ONRx
fi
reboot

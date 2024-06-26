#!/bin/bash

# 检查所需命令是否存在
for cmd in wget chmod sudo; do
    if ! command -v $cmd &> /dev/null; then
        echo "无法找到 $cmd，请在运行此脚本前安装它。"
        exit 1
    fi
done

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
read -p "请输入代码：" country

# 根据用户输入选择对应的配置文件和下载链接，并设置重命名的文件名为 DDNS.sh
case $country in
    "au")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-au-l4ehusajhz18.sh"
        ;;
    "hk")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-hk-l4ehusajhz18.sh"
        ;;
    "jp")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-jp-l4ehusajhz18.sh"
        ;;
    "tw")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-tw-l4ehusajhz18.sh"
        ;;
    "uk")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-uk-l4ehusajhz18.sh"
        ;;
    "in")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-in-l4ehusajhz18.sh"
        ;;
    "us")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-us-l4ehusajhz18.sh"
        ;;
    "nl")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-nl-l4ehusajhz18.sh"
        ;;
    "sg")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-sg-l4ehusajhz18.sh"
        ;;
    "de")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-de-l4ehusajhz18.sh"
        ;;
    "ca")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-ca-l4ehusajhz18.sh"
        ;;
    "sj")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-sj-l4ehusajhz18.sh"
        ;;
    "ru")
        download_link="https://raw.githubusercontent.com/w243420707/-/main/DDNS/hy-ru-l4ehusajhz18.sh"
        ;;
    *)
        echo "无效的输入！"
        exit 1
        ;;
esac

config_file="/root/DDNS.sh"

# 下载配置文件并授予权限，并重命名为 DDNS.sh
echo "正在下载配置文件：$config_file"
wget -O $config_file $download_link
if [ $? -ne 0 ]; then
    echo "下载失败，请检查网络连接或下载链接。"
    exit 1
fi

chmod +x $config_file
sudo $config_file

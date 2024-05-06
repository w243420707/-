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

# 重启 V2bX
echo "正在重启 V2bX..."
V2bX restart

# 查看日志
echo "正在查看 V2bX 日志..."
V2bX log

#!/bin/bash

# 提示用户输入国家代码
echo "请输入要下载配置的国家代码："
echo "1. 澳大利亚（输入 au）"
echo "2. 香港（输入 hk）"
echo "3. 日本（输入 jp）"
echo "4. 台湾（输入 tw）"
echo "5. 英国（输入 uk）"
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
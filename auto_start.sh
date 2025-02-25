#!/bin/bash

# 获取脚本工作目录绝对路径
export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# 加载提示函数定义
source $Server_Dir/scripts/prompt_functions.sh

# 加载.env变量文件
source $Server_Dir/.env

# 变量设置
Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"

## 获取CPU架构信息
# Source the script to get CPU architecture
source $Server_Dir/scripts/get_cpu_arch.sh

# Check if we obtained CPU architecture
if [[ -z "$CpuArch" ]]; then
	echo "Failed to obtain CPU architecture"
	exit 1
fi

## 启动Clash服务
echo -e '\n正在启动Clash服务...'
Text5="服务启动成功！"
Text6="服务启动失败！"
if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64"  ]]; then
	nohup $Server_Dir/bin/clash-linux-amd64 -d $Conf_Dir &> $Log_Dir/clash.log &
	ReturnStatus=$?
	if_success $Text5 $Text6 $ReturnStatus
elif [[ $CpuArch =~ "aarch64" ||  $CpuArch =~ "arm64" ]]; then
	nohup $Server_Dir/bin/clash-linux-arm64 -d $Conf_Dir &> $Log_Dir/clash.log &
	ReturnStatus=$?
	if_success $Text5 $Text6 $ReturnStatus
elif [[ $CpuArch =~ "armv7" ]]; then
	nohup $Server_Dir/bin/clash-linux-armv7 -d $Conf_Dir &> $Log_Dir/clash.log &
	ReturnStatus=$?
	if_success $Text5 $Text6 $ReturnStatus
else
	echo -e "\033[31m\n[ERROR] Unsupported CPU Architecture！\033[0m"
	exit 1
fi

# Output Dashboard access address and Secret
echo ''
echo -e "Clash Dashboard 访问地址: http://127.0.0.1:9090/ui"
echo -e "Secret: ${Secret}"
echo ''
echo -e "本项目完全免费，若你是收费买的，恭喜您，您被骗了！"
echo -e "项目地址：https://github.com/fadinglight9291117/clash-for-linux-backup"
echo -e "项目随时会寄，且行且珍惜！"
echo -e "请执行以下命令开启系统代理: open_proxy\n"
echo -e "若要临时关闭系统代理，请执行: close_proxy\n"

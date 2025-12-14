#!/bin/bash

# Clash API地址
api_url="http://localhost:9090"
Secret="fadinglight"

# 获取Clash代理节点列表
get_proxy_list() {
    # 第一个参数为要操作的 Selector 分组名，默认使用 “🔰国外流量”
    local group="$1"
    if [ -z "$group" ]; then
        group="🔰国外流量"
    fi

    local response
    response=$(curl -s -XGET -H "Content-Type: application/json" -H "Authorization: Bearer ${Secret}" "$api_url/proxies")

    # 保存完整响应，后续用于根据节点名查询延迟
    response_json="$response"

        # 从指定分组的 all 字段中取出所有可选节点，并按延迟升序排序
        # 规则：
        #   - 使用最近一次 history 的 delay 作为排序依据
        #   - delay == 0 视为连接失败，排到最后
        #   - 使用 // [] 避免当 all 为 null 时 jq 报错
        proxies=$(echo "$response" | jq -r --arg g "$group" '
                . as $root
                | [($root.proxies[$g].all // [])[]
                    | . as $p
                    | {name: $p,
                         delay: (
                             ($root.proxies[$p].history // [])
                             | if length > 0 then (.[-1].delay // 0) else 0 end
                         )
                        }
                 ]
                | sort_by(if .delay == 0 then 1000000000 else .delay end)
                | .[].name
        ')

    if [ -z "$proxies" ]; then
        echo "[clash_proxy-selector] 从分组 [$group] 未获取到任何节点，请检查：" >&2
        echo "  - Clash 是否在 $api_url 运行并开启 RESTful API" >&2
        echo "  - Secret 是否正确（当前脚本中为：$Secret）" >&2
        echo "  - /proxies 返回数据中是否存在名为 [$group] 的分组且包含 all 字段" >&2
    fi
}

# 获取Clash代理模式列表
get_mode_list() {
    # 使用您的命令获取代理模式列表，例如：
    # modes=$(your_command_to_get_mode_list)
    # 将代理模式列表保存到变量modes中
    modes=("Global" "Rule")
}

# 显示菜单选项
show_menu() {
    echo "========== Clash代理配置 =========="
    echo "1. 选择代理模式"
    echo "2. 选择代理节点"
    echo "3. 退出"
    echo "==================================="
}

# 选择代理节点
select_proxy() {
    # 这里的参数实际上是 Selector 分组名，例如："🔰国外流量"、"GLOBAL" 等
    local group="$1"
    if [ -z "$group" ]; then
        group="🔰国外流量"
    fi

    get_proxy_list "$group"
    echo "========== 代理节点列表 =========="
    i=1
    # 按行遍历，避免节点名中包含空格被拆分
    IFS=$'\n'
    for proxy in $proxies; do
        # 获取该节点最近一次测速的 delay（毫秒）
        delay=$(echo "$response_json" | jq -r --arg p "$proxy" '(.proxies[$p].history // []) | if length > 0 then (.[-1].delay // "未知") else "未知" end')
        echo "$i. $proxy (delay: ${delay}ms)"
        i=$((i+1))
    done
    unset IFS
    echo "==================================="
    read -p "请选择代理节点（输入编号）：" proxy_index
    proxy=$(echo "$proxies" | sed -n "${proxy_index}p")
    if [[ -n $proxy ]]; then
        # 更新Clash的代理节点设置
        curl -X PUT -s "$api_url/proxies/$group" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${Secret}" \
            --data "{\"name\":\"$proxy\"}" > /dev/null

        echo "分组 [$group] 的代理节点已更新为：$proxy"
    else
        echo "无效的选择！"
    fi
}

# 选择代理模式
select_mode() {
    get_mode_list
    echo "========== 代理模式列表 =========="
    i=1
    #for mode in $modes; do
    for mode in ${modes[@]}; do
        echo "$i. $mode"
        i=$((i+1))
    done
    echo "==================================="
    read -p "请选择代理模式（输入编号）：" mode_index
    mode=$(echo "${modes[$(($mode_index -1))]}") 
    if [[ -n $mode ]]; then
        # 更新Clash的代理模式设置
        curl -XPATCH -s "$api_url/configs" -H "Content-Type: application/json" -H "Authorization: Bearer ${Secret}" -d '{"mode":"'"${mode}"'"}' > /dev/null
        echo "代理模式已更新为：$mode"

        # 根据新的代理模式更新节点配置
        update_nodes "$mode"
    else
        echo "无效的选择！"
    fi
}

update_nodes() {
    local mode=$1
    if [ $mode == "Rule" ]; then
    	mode=Proxy
	select_proxy $mode
    fi
    if [ $mode == "Global" ]; then
    	mode=GLOBAL
	select_proxy $mode
    fi
    # 根据代理模式更新节点配置
    # TODO: 根据实际需求进行更新节点配置的操作
    echo "已根据代理模式 $mode 更新节点配置"
}

# 主程序
while true; do
    show_menu
    read -p "请选择操作（输入编号）：" choice
    case $choice in
        1) select_mode;;
        2) select_proxy;;
        3) break;;
        *) echo "无效的选择！";;
    esac
    echo
done


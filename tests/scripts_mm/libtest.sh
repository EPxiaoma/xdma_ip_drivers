tool_path=../../tools
ERR=255

# 内存映射模式 XDMA 回归脚本使用的公共辅助函数。
# 这些函数负责检查前置条件、将 PCI BDF 映射到 xdma ID、
# 读取 XDMA 配置寄存器、统计通道数量，并执行基础冒烟测试。

############################
#
# 工具函数
#
############################

# 确保只有 root 用户可以运行该脚本。
function check_if_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root" 1>&2
		exit $ERR
	fi
}

function check_cmd_exist() {
	which $1 > /dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		echo "$1 NOT found on the system"
		return $ERR
	fi
	return 0
}

# check_rc <error code> <string> <exit if error 0|1>
function check_rc() {
        local rc=$1

        if [ $rc -ne 0 ]; then
                echo "ERR! $2 failed $rc."
		if [ $3 -gt 0 ]; then
			exit $rc
		fi
        fi
}

# check_dma_dir <h2c|c2h|bi>
function check_dma_dir() {
	if [ "$1" != h2c ] && [ "$1" != c2h ] && [ "$1" != bi ]; then
		echo "bad dma direction: $1."
		exit $ERR
	fi
}

# check_driver_loaded <bdf>
function check_driver_loaded() {
# 输出指定 PCI BDF 在 lspci 中匹配到 "driver xdma" 的数量。
	local bdf=$1
	lspci -s $bdf -v | grep driver | grep xdma | wc -l
}

# bdf_to_xdmaid <bdf>
function bdf_to_xdmaid() {
# 通过设备 sysfs 目录下的 xdma 子目录，将 PCI BDF
# 例如 0000:01:00.0 转换为驱动使用的 xdmaN 前缀。
	cd /sys/bus/pci/devices/$1/
	if [ -d "xdma" ]; then
		cd xdma/
		ls | grep control | cut -d'_' -f1
	fi
}

# cfg_reg_read <xid> <reg addr>
function cfg_reg_read() {
# 使用 reg_rw 读取 XDMA control BAR 寄存器，并返回去掉
# "Read ...: 0x" 前缀后的十六进制值。
	local v=`$tool_path/reg_rw /dev/$1_control $2 w | grep "Read.*:" | sed 's/Read.*: 0x\([a-z0-9]*\)/\1/'`
	if [ -z "$v" ]; then
		return $ERR
	else
		echo $v
		return 0
	fi
}

# cfg_reg_write <xid> <reg addr> <reg value>
function cfg_reg_write() {
# 使用 reg_rw 写入 XDMA control BAR 寄存器。
	local v=`$tool_path/reg_rw /dev/$1_control $2 w $3`
	return $? 
}

# get_streaming_enabled <xid>
function get_streaming_enabled() {
# 第一个 H2C 通道声明流式模式时返回 1，否则返回 0。
	local v=`cfg_reg_read $1 0`
	local rc=$?
	if [ $rc -ne 0 ]; then
		return $rc
	fi

	local id=${v:0:3}
	local stream=${v:4:1}

	local st=0
	if [ "$id" == "1fc" ]; then
		if [ "$stream" == "8" ]; then
			st=1
		fi
	else
		echo "$1 reg 0, $v, bad id $id, $stream."
		return $ERR
	fi
	echo $st
	return 0
}

# get_h2c_channel_count <xid>
function get_h2c_channel_count() {
# 扫描四个标准 H2C 控制寄存器偏移，并检查 XDMA 通道 ID 是否为
# 0x1fc，以统计有效 H2C 通道数量。
	local cnt=0

	for ((i=0; i<=3; i++)); do
		local regval=`cfg_reg_read $1 0x0${i}00`
		if [ $? -ne 0 ]; then
			break
		fi

		local id=${regval:0:3}
		if [ "$id" == "1fc" ]; then
			cnt=$((cnt + 1))
		fi
	done
	echo $cnt
	return 0
}

# get_c2h_channel_count <xid>
function get_c2h_channel_count() {
# 扫描四个标准 C2H 控制寄存器偏移，并检查 XDMA 通道 ID 是否为
# 0x1fc，以统计有效 C2H 通道数量。
	local cnt=0

	for ((i=0; i<=3; i++)); do
		local regval=`cfg_reg_read $1 0x1${i}00`
		if [ $? -ne 0 ]; then
			break
		fi

		local id=${regval:0:3}
		if [ "$id" == "1fc" ]; then
			cnt=$((cnt + 1))
		fi
	done
	echo $cnt
	return 0
}

#############################################################################
#
# 测试用例
#
#############################################################################

# xdma configuration BAR 访问测试。
# TC_cfg_reg_rw <xid>
function TC_cfg_reg_rw() {
# 基础 configuration BAR 读写冒烟测试。
	local reg=0x301c
	local val=0

	cfg_reg_write $reg $val
	local v=$(cfg_reg_read $reg)
	let "v = $v + 0"

	if [ $v -eq $val ]; then
 		echo "ERR ${FUNCNAME[0]} reg value mismatch $v, exp $val"
		exit $ERR
	fi

	cfg_reg_write $reg 1
}

# TC_dma_chrdev_open_close <xid> <h2c count> <c2h count>
function TC_dma_chrdev_open_close() {
# 使用 test_chrdev 辅助工具打开每个 DMA 字符设备。
# 如果这里失败，通常表示驱动没有为对应通道创建可用设备节点。
	local xid=$1
	local h2c_count=$2
	local c2h_count=$3
	local err=0

	for ((i=0; i<$h2c_count; i++)); do
		$tool_path/test_chrdev /dev/${xid}_h2c_$i > /dev/null 2>&1
		if [ $? -ne 0 ];then
 			echo "${FUNCNAME[0]} ${xid}_h2c_$i FAILED"
			exit 1
             	fi
	done

	for ((i=0; i<$c2h_count; i++)); do
		$tool_path/test_chrdev /dev/${xid}_c2h_$i > /dev/null 2>&1
		if [ $? -ne 0 ];then
 			echo "${FUNCNAME[0]} ${xid}_c2h_$i FAILED"
			exit 2
             	fi
	done
}

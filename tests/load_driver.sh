#!/bin/bash
# set -x

# 按指定中断模式加载 xdma 内核模块。
# 脚本会先移除已加载的 xdma 模块，再插入 ../xdma/xdma.ko，
# 最后确认 xdma 字符设备已经注册。

display_help() {
        echo "$0 [interrupt mode]"
        echo "interrupt mode: optional"
        echo "0: auto"
        echo "1: MSI"
        echo "2: Legacy"
        echo "3: MSIx"
        echo "4: do not use interrupt, poll mode only"
        exit;
}

if [ "$1" == "help" ]; then
        display_help
fi;

interrupt_selection=$1
echo "interrupt_selection $interrupt_selection."
device_id=903f

# 确保只有 root 用户可以运行该脚本。
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root" 1>&2
	exit 1
fi

# 移除已有 xdma 模块，确保新的中断或轮询模式参数生效。
lsmod | grep xdma
if [ $? -eq 0 ]; then
	rmmod xdma
	if [ $? -ne 0 ]; then
		echo "rmmod xdma failed: $?"
		exit 1
	fi
fi

# 根据请求的中断模式选择模块参数。
# 如果未显式指定模式，则通过 PCI capability 探测，优先使用 MSI-X，
# 其次 MSI，最后使用 legacy 中断模式。
echo -n "Loading driver..."
case $interrupt_selection in
	"0")
		echo "insmod xdma.ko interrupt_mode=1 ..."
		ret=`insmod ../xdma/xdma.ko interrupt_mode=0`
		;;
	"1")
		echo "insmod xdma.ko interrupt_mode=2 ..."
		ret=`insmod ../xdma/xdma.ko interrupt_mode=1`
		;;
	"2")
		echo "insmod xdma.ko interrupt_mode=3 ..."
		ret=`insmod ../xdma/xdma.ko interrupt_mode=2`
		;;
	"3")
		echo "insmod xdma.ko interrupt_mode=4 ..."
		ret=`insmod ../xdma/xdma.ko interrupt_mode=3`
		;;
	"4")
		echo "insmod xdma.ko poll_mode=1 ..."
		ret=`insmod ../xdma/xdma.ko poll_mode=1`
		;;
	*)
		intp=`sudo lspci -d :${device_id} -v | grep -o -E "MSI-X"`
		intp1=`sudo lspci -d :${device_id} -v | grep -o -E "MSI:"`
	       	if [[ ( -n $intp ) && ( $intp == "MSI-X" ) ]]; then
			echo "insmod xdma.ko interrupt_mode=0 ..."
			ret=`insmod ../xdma/xdma.ko interrupt_mode=0`
	       	elif [[ ( -n $intp1 ) && ( $intp1 == "MSI:" ) ]]; then
			echo "insmod xdma.ko interrupt_mode=1 ..."
			ret=`insmod ../xdma/xdma.ko interrupt_mode=1`
		else
			echo "insmod xdma.ko interrupt_mode=2 ..."
			ret=`insmod ../xdma/xdma.ko interrupt_mode=2`
		fi
		;;
esac

if [ ! $ret == 0 ]; then
	echo "Error: xdma driver did not load properly"
	echo " FAILED"
	exit 1
fi

# 确认模块已经注册 xdma 字符设备。
echo ""
cat /proc/devices | grep xdma > /dev/null
returnVal=$?
if [ $returnVal == 0 ]; then
	# 已识别安装后的设备。
	echo "The Kernel module installed correctly and the xmda devices were recognized."
else
	# 未识别到已安装设备。
	echo "Error: The Kernel module installed correctly, but no devices were recognized."
	echo " FAILED"
	exit 1
fi

echo "DONE"

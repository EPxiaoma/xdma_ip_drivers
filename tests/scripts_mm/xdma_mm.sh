#!/bin/bash

# 完整的内存映射模式 XDMA 回归测试脚本。
# 它会按指定模式加载驱动，根据 PCIe BDF 查找 xdma 设备，
# 执行字符设备检查、DMA 大小扫描、非对齐传输测试，
# 并在 fio 可用时运行性能测试。

####################
#
# 测试设置
#
####################
outdir="/tmp"
driver_modes="0 4"		;# driver mode
address=0
offset=0
io_min=64
io_max=$((1 << 30))		;# 1GB
delay=5				;# delay between each test

fio_time=30
fio_thread_list="4 8"
fio_iodir_list="h2c c2h bi"

####################
#
# 主流程
#
####################

display_help() {
	echo "$0 <xdma BDF> [log dir]"
	echo -e "xdma BDF:\tfpga pci device specified in the format of "
	echo -e "\t\t\t<domain>:<bus>:<device>.<func>"
	echo -e "log dir:\toptional, default to /tmp"
	echo
	exit;
}

if [ $# -eq 0 ]; then
	display_help
fi

bdf=$1
if [ $# -gt 1 ]; then
	outdir=$2
fi

echo "xdma bdf:$bdf, outdir: $outdir"

source ./libtest.sh

check_if_root

curdir=$PWD

# 测试每一种配置的驱动模式。默认覆盖自动中断模式和 poll 模式，
# 用于覆盖驱动中不同的完成路径。
for dm in $driver_modes; do

	echo -e "\n\n====> xdma mode $dm ...\n"

	cd ../../tests

	./load_driver.sh $dm
	if [ $? -ne 0 ]; then
                echo "load_driver.sh failed: $?"
                exit 1
        fi

	cd $curdir
	xid=$(bdf_to_xdmaid $bdf)
	if [ ! -n "$xid" ]; then
        	echo "$bdf, no correponding xdma found, driver mode $dm."
        	exit 1
	fi
	echo "xdma id: $xid."

# 从驱动暴露的 XDMA 控制寄存器中发现通道数量。
	h2c_channels=$(get_h2c_channel_count $xid)
	check_rc $? get_h2c_channel_count 1

	c2h_channels=$(get_c2h_channel_count $xid)
	check_rc $? get_c2h_channel_count 1

	channel_pairs=$(($h2c_channels < $c2h_channels ? \
			$h2c_channels : $c2h_channels))
	echo "channels: $h2c_channels,$c2h_channels, pair $channel_pairs"

	if [ "$channel_pairs" -eq 0 ]; then
		echo "Error: 0 DMA channel pair: $h2c_channels,$c2h_channels."
		exit 1
	fi

	# 测试字符设备。
	# 在运行更大规模传输测试前，先确认每个 DMA 字符设备都能成功打开。
	TC_dma_chrdev_open_close $xid $h2c_channels $c2h_channels

	#
	# 每次只运行一个通道。
	#

	for i in {1..80}; do echo -n =; done
	echo -e "\nSingle H2C Channel $h2c_channels io test ...\n"
	for ((i=0; i<$h2c_channels; i++)); do
		# 仅 H2C 流量无法通过 C2H 读回比较，因此对齐大小扫描只检查
		# 命令是否成功。非对齐用例覆盖非页对齐偏移和短传输长度。
		./io_sweep.sh $xid $i 4 $address $offset \
			$io_min $io_max 0 1
		check_rc $? "h2c-$i" 1
		./unaligned.sh $xid $i 4 0 1 
		check_rc $? "h2c-$i-unaligned" 1
	done

	for i in {1..80}; do echo -n =; done
	echo -e "\nSingle C2H Channel $c2h_channels io test ...\n"
	for ((i=0; i<$c2h_channels; i++)); do
		./io_sweep.sh $xid 4 $i $address $offset \
			$io_min $io_max 0 1
		check_rc $? "c2h-$i" 1
		./unaligned.sh $xid 4 $i 0 1 
		check_rc $? "c2h-$i-unaligned" 1
	done

	for i in {1..80}; do echo -n =; done
	echo -e "\nh2c/c2h pair $channel_pairs io test with data check ...\n"
	for ((i=0; i<$channel_pairs; i++)); do
		# 成对测试会开启一致性校验，因为写入 H2C 的数据可以通过匹配的
		# C2H 通道读回。
		./io_sweep.sh $xid $i $i $address $offset $io_min $io_max 1 1
		check_rc $? "pair-$i" 1
		./unaligned.sh $xid $i $i 1 1 
		check_rc $? "pair-$i-unaligned" 1
	done

	#
	# fio 测试：系统安装 fio 时执行可选性能扫描。
	#

	check_cmd_exist fio
	if [ "$?" -ne 0 ]; then
		echo "fio test skipped"
		continue
	fi

	for i in {1..80}; do echo -n =; done
	echo -e "\nfio test  ...\n"
	
	#
	# 结果目录结构：
	# - <outdir/fio>
	#       - <通道数量>
	#               - <方向：h2c c2h bi>
	#
	for ((i=1; i<=$channel_pairs; i++)); do
		for iodir in $fio_iodir_list; do
			out=${outdir}/fio_d${dm}/${i}/${iodir}
			mkdir -p ${out}
			rm -rf ${out}/*

			for (( sz=$io_min; sz<=$io_max; sz=$(($sz*2)) )); do
				for thread in $fio_thread_list; do
                                	name=${sz}_t${thread}
                                	echo "$iodir $i: $name ..."
					./fio_test.sh $xid $iodir $i ${sz} \
						${fio_time} ${thread} ${out}
				done
			done
	       	done
       	done
	./fio_parse_result.sh ${outdir}/fio_d${dm}

	echo -e "\n\n====> xdma mode $dm COMPLETED.\n"
done

echo "$0: COMPLETED."

#!/bin/bash

# 内存映射模式 XDMA 数据通路测试。
# 脚本通过已启用的 H2C 通道写入已知数据，再通过 C2H 通道读回，
# 并比较读回字节是否一致。

display_help() {
	echo "$0 <xdma id> <io size> <io count> <h2c #> <c2h #>"
	echo -e "xdma id:\txdma[N] "
	echo -e "io size:\tdma transfer size in byte"
	echo -e "io count:\tdma transfer count"
       	echo -e "h2c #:\tnumber of h2c channels"
	echo -e "c2h #:\tnumber of c2h channels"
       	echo
       
	exit 1
}

if [ $# -eq 0 ]; then
	display_help
fi

xid=$1
transferSz=$2
transferCount=$3
h2cChannels=$4
c2hChannels=$5

tool_path=../tools

testError=0
# 运行 PCIe DMA 内存映射写入/读回测试。
echo "Info: Running PCIe DMA memory mapped write read test"
echo -e "\ttransfer size:  $transferSz, count: $transferCount"

# 写入四段连续地址空间。传输会分配到已启用的 H2C 通道，
# 用于并行覆盖多通道 DMA 引擎。
if [ $h2cChannels -gt 0 ]; then
	# 遍历四个大小为 $transferSz 的块并写入数据。
	for ((i=0; i<=3; i++)); do
		addrOffset=$(($transferSz * $i))
		curChannel=$(($i % $h2cChannels))
	       	echo "Info: Writing to h2c channel $curChannel at address" \
		       "offset $addrOffset."
		$tool_path/dma_to_device -d /dev/${xid}_h2c_${curChannel} \
		       	-f data/datafile${i}_4K.bin -s $transferSz \
			-a $addrOffset -c $transferCount &
		# 如果所有通道都有正在执行的事务，则等待它们完成。
		if [ $(($curChannel+1)) -eq $h2cChannels ]; then
			echo "Info: Wait for current transactions to complete."
			wait
		fi
	done
fi

# 等待最后一批事务完成。
wait

# 通过 C2H 通道读回相同的四段地址空间。每次运行都会重新生成输出文件，
# 避免和旧数据比较。
if [ $c2hChannels -gt 0 ]; then
	# 遍历四个大小为 $transferSz 的块并读回数据。
	for ((i=0; i<=3; i++)); do
		addrOffset=$(($transferSz * $i))
		curChannel=$(($i % $c2hChannels))

		rm -f data/output_datafile${i}_4K.bin
		echo "Info: Reading from c2h channel $curChannel at " \
			"address offset $addrOffset."
		$tool_path/dma_from_device -d /dev/${xid}_c2h_${curChannel} \
		       	-f data/output_datafile${i}_4K.bin -s $transferSz \
		       	-a $addrOffset -c $transferCount &
		# 如果所有通道都有正在执行的事务，则等待它们完成。
		if [ $(($curChannel+1)) -eq $c2hChannels ]; then
			echo "Info: Wait for current transactions to complete."
			wait
		fi
	done
fi

# 等待最后一批事务完成。
wait

# 只有 H2C 和 C2H 都存在时才做数据一致性校验。
# 只有单方向通道时仍可发起传输，但无法完成写入后读回比较。
if [ $h2cChannels -eq 0 ]; then
	echo "Info: No data verification was performed because no h2c " \
		"channels are enabled."
elif [ $c2hChannels -eq 0 ]; then
	echo "Info: No data verification was performed because no c2h " \
		"channels are enabled."
else
	echo "Info: Checking data integrity."
	for ((i=0; i<=3; i++)); do
		cmp data/output_datafile${i}_4K.bin data/datafile${i}_4K.bin \
			-n $transferSz
		returnVal=$?
	       	if [ ! $returnVal == 0 ]; then
			echo "Error: The data written did not match the data" \
			       " that was read."
			echo -e "\taddress range: " \
				"$(($i*$transferSz)) - $((($i+1)*$transferSz))"
			echo -e "\twrite data file: data/datafile${i}_4K.bin"
			echo -e "\tread data file:  data/output_datafile${i}_4K.bin"
			testError=1
		else
			echo "Info: Data check passed for address range " \
				"$(($i*$transferSz)) - $((($i+1)*$transferSz))"
		fi
	done
fi

# 如果测试过程中发现错误，则以错误码退出。
if [ $testError -eq 1 ]; then
	echo "Error: Test completed with Errors."
	exit 1
fi

# 报告所有测试通过并退出。
echo "Info: All PCIe DMA memory mapped tests passed."
exit 0

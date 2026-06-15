#!/bin/bash

# XDMA 快速测试入口。
# 该脚本会检测已启用的 XDMA 通道，并判断 IP 配置为内存映射模式
# 还是流式模式，然后分发到对应的测试脚本。

#---------------------------------------------------------------------
# 脚本变量
#---------------------------------------------------------------------
tool_path=../tools

# 本测试使用的 PCIe DMA 传输大小。
# 修改该变量时，需要确保 FPGA 中对应地址范围有效。
# 当 PCIe DMA 核配置为内存映射事务时，本测试会使用
# 0 到 4 * transferSize 范围内的地址。
transferSize=1024
# 设置每次数据传输的重复次数。
# 增大该值可以让多个通道上的传输在更长时间内重叠执行。
transferCount=1

# 扫描 H2C 通道控制寄存器。
# 寄存器偏移 0x000、0x100、0x200、0x300 分别对应 H2C 通道实例。
# 通道 ID 为 0x1fc 表示该通道存在；stream-enable 字段用于判断
# XDMA 核是否工作在流式模式。
isStreaming=0
h2cChannels=0
for ((i=0; i<=3; i++)); do
	v=`$tool_path/reg_rw /dev/xdma0_control 0x0${i}00 w`
	returnVal=$?
	if [ $returnVal -ne 0 ]; then
		break;
	fi

	#v=`echo $v | grep -o  '): 0x[0-9a-f]*'`
	statusRegVal=`$tool_path/reg_rw /dev/xdma0_control 0x0${i}00 w | grep "Read.*:" | sed 's/Read.*: 0x\([a-z0-9]*\)/\1/'`
	channelId=${statusRegVal:0:3}
	streamEnable=${statusRegVal:4:1}

	if [ $channelId == "1fc" ]; then
		h2cChannels=$((h2cChannels + 1))
		if [ $streamEnable == "8" ]; then
			isStreaming=1
		fi
	fi
done
echo "Info: Number of enabled h2c channels = $h2cChannels"

# 扫描 C2H 通道控制寄存器。
# 寄存器偏移 0x1000、0x1100、0x1200、0x1300 分别对应 C2H 通道实例。
# 脚本会统计所有通道 ID 为 0x1fc 的有效通道。
c2hChannels=0
for ((i=0; i<=3; i++)); do
	v=`$tool_path/reg_rw /dev/xdma0_control 0x1${i}00 w`
	returnVal=$?
	if [ $returnVal -ne 0 ]; then
		break;
	fi

	$tool_path/reg_rw /dev/xdma0_control 0x1${i}00 w | grep "Read.*: 0x1fc" > /dev/null
	statusRegVal=`$tool_path/reg_rw /dev/xdma0_control 0x1${i}00 w | grep "Read.*:" | sed 's/Read.*: 0x\([a-z0-9]*\)/\1/'`
	channelId=${statusRegVal:0:3}

	# 不会同时混合 MM 和 ST 通道，因此这里不需要再次检查流式使能位。
	if [ $channelId == "1fc" ]; then
		c2hChannels=$((c2hChannels + 1))
	fi
done
echo "Info: Number of enabled c2h channels = $c2hChannels"

# 打印 PCIe DMA 核是内存映射模式还是流式模式。
if [ $isStreaming -eq 0 ]; then
	echo "Info: The PCIe DMA core is memory mapped."
else
	echo "Info: The PCIe DMA core is streaming."
fi

# 确认至少识别到一个 DMA 通道。
if [ $h2cChannels -eq 0 -a $c2hChannels -eq 0 ]; then
	echo "Error: No PCIe DMA channels were identified."
	exit 1
fi

# 根据 XDMA 数据通路类型选择对应测试。
testError=0
if [ $isStreaming -eq 0 ]; then

	# 运行 PCIe DMA 内存映射写入/读回测试。
	./dma_memory_mapped_test.sh xdma0 $transferSize $transferCount $h2cChannels $c2hChannels
	returnVal=$?
	 if [ $returnVal -eq 1 ]; then
		testError=1
	fi

else

	# 流式测试需要成对的 H2C/C2H 通道，因为示例设计会把写入
	# H2C 的流数据回环到匹配的 C2H 通道。
	channelPairs=$(($h2cChannels < $c2hChannels ? $h2cChannels : $c2hChannels))
	if [ $channelPairs -gt 0 ]; then
		./dma_streaming_test.sh $transferSize $transferCount $channelPairs
		returnVal=$?
		if [ $returnVal -eq 1 ]; then
			testError=1
		fi
	else
		echo "Info: No PCIe DMA stream channels were tested because no h2c/c2h pairs were found."
	fi

fi

# 如果测试过程中发现错误，则以错误码退出。
if [ $testError -eq 1 ]; then
	echo "Error: Test completed with Errors."
	exit 1
fi

# 报告所有测试通过并退出。
echo "Info: All tests in run_tests.sh passed."
exit 0

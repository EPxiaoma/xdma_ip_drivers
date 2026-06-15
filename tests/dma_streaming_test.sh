#!/bin/bash

# 流式模式 XDMA 回环测试。
# 对每组 H2C/C2H 通道，脚本先启动 C2H 读操作，再向对应 H2C
# 写入流数据，最后比较读回数据。

transferSize=$1
transferCount=$2
channelPairs=$3

tool_path=../tools

testError=0

# 运行 PCIe DMA 流式测试。
echo "Info: Running PCIe DMA streaming test"
echo "      transfer size:  $transferSize"
echo "      transfer count: $transferCount"
echo "Info: Only channels that have both h2c and c2h will be tested as the other"
echo "      interfaces are left unconnected in the PCIe DMA example design. "

# 先启动所有 C2H 通道，再启动 H2C 写入，确保进入的流数据有接收端等待，
# 并能被保存到输出文件。
for ((i=0; i<$channelPairs; i++))
do
  rm -f data/output_datafile${i}_4K.bin
  echo "Info: DMA setup to read from c2h channel $i. Waiting on write data to channel $i."
  $tool_path/dma_from_device -d /dev/xdma0_c2h_${i} -f data/output_datafile${i}_4K.bin -s $transferSize -c $transferCount &
done

# 等待 DMA 接收端准备好接收数据。
sleep 1s

# 启动 H2C 写入。在 XDMA 示例设计中，写入 H2C[i] 的流数据应从
# C2H[i] 返回。
for ((i=0; i<$channelPairs; i++))
do
  echo "Info: Writing to h2c channel $i. This will also start reading data on c2h channel $i."
  $tool_path/dma_to_device -d /dev/xdma0_h2c_${i} -f data/datafile${i}_4K.bin -s $transferSize -c $transferCount &
done

# 等待当前事务完成。
echo "Info: Wait the for current transactions to complete."
wait

# 按指定传输大小比较每个输出文件和对应源文件。
# 任一通道数据不一致都会使整个测试失败。
for ((i=0; i<$channelPairs; i++))
do
  echo "Info: Checking data integrity."
  cmp data/output_datafile${i}_4K.bin data/datafile${i}_4K.bin -n $transferSize
  returnVal=$?
  if [ ! $returnVal == 0 ]; then
    echo "Error: The data written did not match the data that was read."
    echo "       write data file: data/datafile${i}_4K.bin"
    echo "       read data file:  data/output_datafile${i}_4K.bin"
    testError=1
  else
    echo "Info: Data check passed for c2h and h2c channel $i."
  fi
done

# 如果测试过程中发现错误，则以错误码退出。
if [ $testError -eq 1 ]; then
  echo "Error: Test completed with Errors."
  exit 1
fi

# 报告所有测试通过并退出。
echo "Info: All PCIe DMA streaming tests passed."
exit 0

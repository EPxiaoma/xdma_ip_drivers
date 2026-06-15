#!/bin/bash

# 对每个通道运行 XDMA 硬件性能计数工具。
# 测试结果追加写入 hw_log_h2c.txt 和 hw_log_c2h.txt，
# 传输大小从 64 字节倍增到 4 MB。

tool_path=../tools

h2cchannels=$1
c2hchannels=$2
if [ "$#" -ne 2 ];then
  echo "usage $0 <no:of h2cchannels> <no:of c2hchannels>"
  exit -1
fi
rm hw_log_h2c.txt
rm hw_log_c2h.txt
echo "h2cchannels $h2cchannels"
echo "c2hchannels $c2hchannels"
h2c=/dev/xdma0_h2c_0
c2h=/dev/xdma0_c2h_0
iter=1

out_h2c=hw_log_h2c.txt
out_c2h=hw_log_c2h.txt
for ((i=0;i<h2cchannels;i++))
do
# 使用相同通道索引测试 H2C 和 C2H 设备节点。
# 如果需要双向测试，调用者应传入匹配的通道数量。
h2c=/dev/xdma0_h2c_$i
c2h=/dev/xdma0_c2h_$i
byte=64
# 按 2 的幂扫描传输大小，并记录硬件计数输出。
for ((j=0; j<=16; j++)) do
	echo "** HW H2C = $h2c bytecount = $byte and iteration = $iter" | tee -a $out_h2c
	$tool_path/performance -d $h2c -c $iter -s $byte | tee -a $out_h2c
	byte=$(($byte*2))
done
wait
byte=64
# 对 C2H 方向重复相同的大小扫描。
for ((j=0; j<=16; j++)) do
	echo "** HW C2H = $c2h bytecount = $byte and iteration = $iter" | tee -a $out_c2h
	$tool_path/performance -d $c2h -c $iter -s $byte | tee -a  $out_c2h
	byte=$(($byte*2))
done

done

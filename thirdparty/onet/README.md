# onet（Jai）

从 olib `d3943f1b4608fdc22983ac57f73332f0ada1e3ae` 的 `thirdparty/onet`
迁移。实现按子模块导入，不需要 Odin 编译器或同级 olib 检出。

```jai
NetCore :: #import "thirdparty/onet/core";
Runtime :: #import "thirdparty/onet/runtime";
UDP :: #import "thirdparty/onet/transport/udp";
```

编译时添加 `-import_dir <JaiLib>`。可调用用例见 `tests/`。

| 模块 | 内容 |
| --- | --- |
| core、wire、values | 位流、消息协议、值编解码、Decimal、引用和拥有内存的容器 |
| collections、objects | 集合变更历史、对象注册与复制 |
| transport | 通用驱动、网络条件模拟、memory、ENet、原生 UDP |
| session、rpc | 会话、准入、RPC 路由和拒绝报告 |
| scenes、simulation、physics、runtime | 场景迁移、预测回放、物理同步和世界运行时 |

原生 UDP 支持 IPv4/IPv6、cookie 握手、速率限制、分片重传和端点探测。
cookie 使用 SHA-256/HMAC 和操作系统随机数；这是地址验证，不提供数据加密。
Windows ENet 1.3.17 静态库和许可位于 `transport/enet/native/`；
该二进制来自 Odin vendor ENet。其他原生平台需要系统 ENet 库。

## 验证

```powershell
python tools/check/main.py --only onet
# 构建后可按测试名称片段筛选：
./build/check/onet_tests.exe parity_
```

统一检查包含所有子模块的 `-no_dce` 类型检查，以及 242 组迁移测试和一组
SHA-256/HMAC 已知答案测试；全部 243 组、27,237 项断言通过。
网络测试需要允许本机 UDP/IPv6 回环通信。
当前验收平台为 Windows x64、jacket 0.35.1；POSIX 分支未做运行验收。

Jai 的 `int` 与 `s64` 为同一类型，不能保留 Odin 的两套独立类型标识；
128 位无符号整数以双 `u64` 实现，Decimal 保留 96 位有效数。
地址联合体改为带标签的 `Address`，互斥锁显式初始化/销毁，分配器随拥有者保存。
测试夹具修正了原有释放后读取和回调缓冲区过早释放的问题；
ENet 大快照测试使用有上限的收敛等待，保留最终状态相等断言。

本次迁移库代码和行为测试；原 Odin 的示例程序及独立网络验证 CLI 尚未翻译。
参照快照中未找到 onet 独立许可证，保留来源记录，不另行推定授权；
ENet 的许可证仅覆盖相应原生依赖。

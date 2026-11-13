# Jai shader 工具

```powershell
python tools/shaders/main.py --dir path/to/shaders
python tools/shaders/main.py --dir path/to/shaders --validate
python tools/shaders/main.py --dir path/to/shaders --check
```

HLSL 使用 vertex_main / fragment_main；默认 HLSL→SPIR-V→DXIL/MSL。
`--dxil direct --dxc PATH` 使用 DXC 成对编译 vertex/fragment，保留 SPIR-V/MSL。
`--shadercross PATH` 或 SHADERCROSS 可指定工具；工具缺失明确失败，不产生空产物。

`.oshader` 由同目录 Jai main 调用库内 `kit/rendering/shader/lang` 解析，输出各 Pass、
Sprite 实例化顶点变体及 schema/effect JSON，并用运行时 manifest reader 读回验证。
`--validate` 不调用外部 shader 编译器，仅完成该解析/manifest 验证。
标准 `olib/*.hlsli` 保留文件格式命名，在独占临时工作区提供；不复制进用户源码目录。

全部阶段成功后才写 Compiled；记录源码、标准 include、工具入口、编译器及产物的 SHA-256。
`--check` 检查源码/策略/产物，`--check-build` 还核查编译器字节。记录最后发布，
中断造成混合批次会被检查拒绝。旧的、未带记录的 Compiled 需重建后才能通过此检查。
不自动生成 Web GLSL；Foster Web 源码继续由 `foster/tools/build_glsl_es.py` 维护。

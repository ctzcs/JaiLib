# Jai 声明枚举生成入口

```powershell
python tools/run.py auto_gen --source path/to/module --tag entity --enum Entity_Kind --out kinds_generated.jai
python tools/run.py auto_gen --source path/to/module --tag entity --enum Entity_Kind --out kinds_generated.jai --check
```

复用现有 core/codegen 的 Jai note/声明扫描器，不调用 Odin parser。只负责将带 tag 的顶层声明
按名字排序生成枚举；序号不作为持久协议。输出由所属 module.jai 显式 `#load`。
语法或生成失败保留已有文件，`--check` 不写回。它不是完整 Jai AST 工具；core/codegen 的
全面对位仍保留原来的独立验收范围，本次只接入并验证该 CLI。

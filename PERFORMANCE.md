# PDFTextGuard 迭代与性能记录

每个版本每组样本在同机同一 Node.js 环境先预热一次，再按轮次交替顺序运行 9 次。计时覆盖进程启动、两份输入读取、PDF 检查与 JSON 输出。每次都验证退出码为 0、用字对齐数和语义比较数与预期一致。v0.0.12 起以 v0.0.11 为基线，两组样本的中位耗时各允许至多增加 10%。[前五版计时](verification/history/benchmark-v0.0.5.json) · [当前版对照](verification/benchmark-results.json)

| 版本 | 本轮修改 | 单页 300 字形中位耗时 | 48 页 14,400 字形中位耗时 |
| --- | --- | ---: | ---: |
| v0.0.1 | 保留的起点 | 176.30 ms | 987.33 ms |
| v0.0.2 | 共享字体和已用 CID 缓存，延迟生成诊断 | 176.84 ms | 272.94 ms |
| v0.0.3 | 嵌套 Form XObject 和输入流缓存 | 180.89 ms | 279.42 ms |
| v0.0.4 | 页面旋转和裁切坐标归一化 | 178.28 ms | 284.83 ms |
| v0.0.5 | 可选的唯一位置配对，收窄位置索引查询 | 180.01 ms | 279.72 ms |

48 页样本由两份既有 PDFKit 导出构造。每份 PDF 的 48 页各有独立的压缩内容流，共用同一个嵌入字体对象。两份文件实际使用了不同的字体子集。最终版在这组样本上比首版耗时减少 **71.7%**，约为 **3.53 倍速度**。共享字体的多页样本适合测重复解析开销，这组结果不代表所有 PDF 的收益。

逐轮命令行结果保存在 `verification/history/`。最新 ZIP 解压后可复跑 [smoke.cjs](verification/smoke.cjs) 和 [verify_reference.py](verification/verify_reference.py)。后者用 pypdf 核对对象和偏移，用 PDFium 核对指定样本的像素和文字。

在源码工作区复跑五版本性能测试。`dist` 需要对应五个版本的 CJS。

```powershell
python .\verification\benchmark_fixtures.py
node .\verification\benchmark.cjs v0.0.1 v0.0.2 v0.0.3 v0.0.4 v0.0.5
```

比较结果输出到 `.work/benchmark/comparison.json`。

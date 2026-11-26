# PDFTextGuard v0.0.16 评审一页纸

**PDF 生成器升级后，页面仍然一样，复制和搜索的字可能已经变了。** PDFTextGuard 面向维护 PDF 导出流程的工程师。它比较同一源文档的两次导出，在 CI 中识别文字层回归并给出可在 PDF 内复核的定位。

## 两分钟复现

下载并解压 v0.0.16 演示包，用 Node.js 22.3 或更新版本运行 `node verification/demo.cjs`。命令依次展示正常换子集、真实 PDFKit 回归和加密输入，结果为 `0`、`1`、`2`。运行 `node verification/smoke.cjs` 可复跑包括 QPDF 在内的完整样本。[固定演示包](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.16/PDFTextGuard-v0.0.16.zip) · [ZIP 校验值](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.16/SHA256SUMS)

| 对照 | 独立参考 | 门禁证据 |
| --- | --- | --- |
| PDFKit 0.18.0 与 0.17.2 的真实导出 | PDFium 像素一致，提取文字不同 | `1`。第一页的 ToUnicode 规则声明 1 个范围，实际 2 个 |
| 同源文档换字体子集 | PDFium 像素与文字一致，pypdf 复核嵌入字体不同 | `0`。对齐 300 次用字，首个字形编号从 1 变为 300 |
| PDFBox 3.0.4 的传统与默认压缩保存 | PDFium 像素与文字一致，pypdf 识别对象流 | `0`。对齐并检查 38 次绘制 |
| PDFBox 压缩版的受控错映射 | 像素一致，PDFium 和 pypdf 都提取出 `Z` 代替 `!` | `1`。第一页，ToUnicode `13 0 R`，解压后规则字节 `258..287` |
| QPDF 12.4.1 压缩转存 | 正常转存保持像素及文本。另一份在转存前预置错映射，转存后仍能复现 | 正常对齐 300 次绘制，返回 `0`。错映射返回 `1`，定位第 1 页 ToUnicode `16 0 R` 的字节范围 `[2066, 2396)` |

上游 PDFKit 问题来自两个真实发布版本。PDFBox 和 QPDF 的错映射样本为受控对照，用来检验像素保持时的映射定位。[PDFKit #1659](https://github.com/foliojs/pdfkit/issues/1659) · [PDFBox 样本](verification/fixtures/pdfbox.json) · [QPDF 样本](verification/fixtures/qpdf.json) · [独立复核](verification/reference-results.json)

## 核心实现与工程取舍

MoonBit 负责 PDF 结构检查、字形轮廓与位置配对、CMap 语法和语义比较。匹配时使用实际画出的字形，允许字体子集重新编号。诊断保留页码、码值、字体及 CMap 对象、解压后的字节范围。单次保存的交叉引用流和对象流共用解压预算。加密、增量保存及无法可靠配对时返回 `2`，交给调用方复核。

GitHub Action 提供 JSON 与可选 Markdown，阻断回归和无法确认的结果。MoonBit 独立示例直接调用发布库，比较七组样本并检查报告。[CI 模板](examples/pdf-export-gate.yml) · [公开复跑](https://github.com/WeiR-h/pdftextguard/actions/workflows/release-replay.yml) · [MoonBit 示例](examples/moonbit-consumer/README.md) · [Mooncakes v0.0.16](https://mooncakes.io/docs/WeiR-h/pdftextguard@0.0.16/)

批量门禁可在一次 Action 安装后依清单检查多组导出，保留各组证据并汇总放行结果。[批量样例](examples/fixture-pairs.json) · [工作流模板](examples/pdf-export-suite.yml)

AI 辅助实现、生成对照、整理文档及排查测试失败。发布前复跑 CLI、MoonBit 示例及独立阅读器，回执绑定当前可执行文件的散列。[本版验证回执](verification/acceptance-results.json) · [更新记录](CHANGELOG.md) · [性能测量](PERFORMANCE.md) · [样本和依赖许可](THIRD_PARTY.md) · [v0.0.8 历史演示](https://github.com/WeiR-h/pdftextguard/releases/tag/v0.0.8)

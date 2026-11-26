# PDFTextGuard v0.1.0 评审一页纸

**PDF 生成器升级后，页面仍然一样，复制和搜索的字可能已经变了。** PDFTextGuard 面向维护 PDF 导出流程的工程师。它比较同一源文档的两次导出，在 CI 中识别文字层回归并给出可在 PDF 内复核的定位。

## 两分钟复现

解压 v0.1.0 演示包，用 Node.js 22.3 或更新版本运行 `node verification/quote_demo.cjs`。命令给出中英报价单的通过、回归、无法确认三种结果。再运行 `node verification/demo.cjs` 看 PDFKit 的真实上游回归。包内附 90 秒字幕演示。[演示包](https://github.com/WeiR-h/pdftextguard/releases/download/v0.1.0/PDFTextGuard-v0.1.0.zip) · [ZIP 校验值](https://github.com/WeiR-h/pdftextguard/releases/download/v0.1.0/SHA256SUMS)

| 对照 | 独立参考 | 门禁证据 |
| --- | --- | --- |
| 中英报价单 · PDFBox 两种保存 | 两页像素与文字一致 | `0`。逐页通过，检查 224 次绘制 |
| 中英报价单 · 受控错映射 | 两页像素一致，PDFium 和 pypdf 都提取出“台计”代替“合计” | `1`。第 2 页，字体 `6 0 R`，ToUnicode `13 0 R`，规则字节 `[720, 740)` |
| 中英报价单 · 加密对照 | pypdf 确认文件加密 | `2`。无法确认，交给调用方复核 |
| PDFKit 0.18.0 与 0.17.2 · 真实导出 | 像素一致，提取文字不同 | `1`。第 1 页 CMap 声明 1 个范围，实际 2 个 |

[报价单样本来源](verification/fixtures/quote.json) · [PDFKit #1659](https://github.com/foliojs/pdfkit/issues/1659) · [独立复核](verification/reference-results.json)

## 核心实现与工程取舍

MoonBit 负责 PDF 结构检查、字形轮廓与位置配对、CMap 语法和语义比较。匹配时使用实际画出的字形，允许字体子集重新编号。诊断保留页码、码值、字体及 CMap 对象、解压后的字节范围。单次保存的交叉引用流和对象流共用解压预算。加密、增量保存及无法可靠配对时返回 `2`，交给调用方复核。

GitHub Action 提供 JSON 与可选 Markdown，阻断回归和无法确认的结果。MoonBit 独立示例直接调用发布库，比较七组样本并检查报告。[CI 模板](examples/pdf-export-gate.yml) · [公开复跑](https://github.com/WeiR-h/pdftextguard/actions/workflows/release-replay.yml) · [MoonBit 示例](examples/moonbit-consumer/README.md) · [Mooncakes v0.1.0](https://mooncakes.io/docs/WeiR-h/pdftextguard@0.1.0/)

批量门禁在作业摘要列出组别、页码和原因。第二组进程异常或报告写入失败时，第一组的 JSON 与 Markdown 仍可取回。[报价单批量清单](examples/quote-pairs.json) · [工作流模板](examples/pdf-export-suite.yml)

AI 辅助实现、生成对照、整理文档及排查测试失败。发布前复跑 CLI、MoonBit 示例及独立阅读器，回执绑定当前可执行文件的散列。[本版验证回执](verification/acceptance-results.json) · [更新记录](CHANGELOG.md) · [性能测量](PERFORMANCE.md) · [样本和依赖许可](THIRD_PARTY.md) · [v0.0.8 历史演示](https://github.com/WeiR-h/pdftextguard/releases/tag/v0.0.8)

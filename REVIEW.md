# PDFTextGuard 评审一页纸

**PDF 生成器升级后，页面仍然一样，复制和搜索的字可能已经变了。** PDFTextGuard 面向维护 PDF 导出流程的工程师。它比较同一源文档的两次导出，在 CI 中识别文字层回归并给出可在 PDF 内复核的定位。

## 两分钟复现

下载并解压 `v0.0.8` 演示包，用 Node.js 22.3 或更新版本运行 `node verification/demo.cjs`。命令依次展示正常换子集、真实 PDFKit 回归、以及范围外输入。ZIP 也包含 90 秒字幕演示、原始样本和独立验收记录。[固定演示包](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.8/PDFTextGuard-v0.0.8.zip)

| 对照 | 独立参考 | 门禁证据 |
| --- | --- | --- |
| PDFKit 0.18.0 与 0.17.2 的真实导出 | PDFium 像素一致，提取文字不同 | `1`。第一页的 ToUnicode 规则声明 1 个范围，实际 2 个 |
| 同源文档换字体子集 | PDFium 像素与文字一致，pypdf 复核嵌入字体不同 | `0`。对齐 300 次用字，首个字形编号从 1 变为 300 |
| PDFBox 3.0.4 的传统与默认压缩保存 | PDFium 像素与文字一致，pypdf 识别对象流 | `0`。对齐并检查 38 次绘制 |
| PDFBox 压缩版的受控错映射 | 像素一致，PDFium 和 pypdf 都提取出 `Z` 代替 `!` | `1`。第一页，ToUnicode `13 0 R`，解压后规则字节 `258..287` |

上游 PDFKit 问题和 PDFBox 的默认保存均有公开来源。PDFBox 错映射由项目按固定规则生成，作为检验定位能力的对照。[PDFKit #1659](https://github.com/foliojs/pdfkit/issues/1659) · [PDFBox 保存说明](https://pdfbox.apache.org/3.0/migration.html#compressed-saving-by-default) · [PDFBox 样本与校验值](verification/fixtures/pdfbox.json) · [独立复核](verification/reference-results.json)

## 核心实现与工程取舍

MoonBit 负责 PDF 结构检查、字形轮廓与位置配对、CMap 语法和语义比较。匹配时使用实际画出的字形，允许字体子集重新编号。诊断保留页码、码值、字体及 CMap 对象、解压后的字节范围。单次保存的交叉引用流和对象流共用解压预算。加密、增量保存及无法可靠配对时返回 `2`，交给调用方复核。

GitHub Actions 示例在其调用方提供两份导出后，可校验发布包、执行门禁并留存 JSON。Mooncakes 提供同一个 MoonBit 扫描与比对 API。[CI 模板](examples/pdf-export-gate.yml) · [公开复跑](https://github.com/WeiR-h/pdftextguard/actions/workflows/release-replay.yml) · [Mooncakes v0.0.8](https://mooncakes.io/docs/WeiR-h/pdftextguard@0.0.8/)

AI 辅助实现、生成对照、整理文档及排查测试失败。每版以同一组旧场景、独立阅读器、带校验值的构建和公开 CI 核对交付结果。 [更新记录](CHANGELOG.md) · [性能测量](PERFORMANCE.md) · [样本和依赖许可](THIRD_PARTY.md)

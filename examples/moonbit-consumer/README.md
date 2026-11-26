# 从 MoonBit 调用 PDFTextGuard

这是独立的 MoonBit 项目。它通过 Mooncakes 安装清单中固定的模块版本。用 JavaScript 后端和 Node.js 运行。示例读取两份本地 PDF，直接调用 `@guard.check`，输出同一份结构化报告。

从 PDFTextGuard 源码或发行 ZIP 的顶层进入示例目录。以下命令可以在 Windows PowerShell 或 Bash 运行。

```sh
cd examples/moonbit-consumer
moon run --target js . -- ../../verification/fixtures/pdfkit-0.18.0-300.pdf ../../verification/fixtures/subset-reordered.pdf
```

将第二个路径的文件名换成下表所列样本可复跑其他结果。JSON 的 `exit_code` 为库返回的结果。集成方也可读取 `outcome` 和 `diagnostics`。

| 候选 | 结果 |
| --- | --- |
| `subset-reordered.pdf` | `0`。更换字体子集后成功对齐 300 次绘制。 |
| `pdfkit-0.17.2-300.pdf` | `1`。第 1 页 CMap 声明 1 个范围，实际有 2 个。 |
| `qpdf-wrong-unicode.pdf` | `1`。转存后仍定位到预置的 `!` 到 `Z` 错映射。 |
| `encrypted.pdf` | `2`。加密输入无法确认。 |

两页报价单可用下面的命令复跑。报告的 `page_results` 会标记第 2 页回归，并给出一处映射变化。

```sh
moon run --target js . -- ../../verification/fixtures/quote-classic.pdf ../../verification/fixtures/quote-wrong-unicode.pdf
```

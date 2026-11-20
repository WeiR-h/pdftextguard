# 更新记录

## v0.0.1 · 2026-11-19

- 提供可离线运行的 PDFTextGuard CLI 及 MoonBit `check` 库接口。
- 比较同源双 PDF 的实际用字和 Unicode 映射。报告页码、内容流、字体与 ToUnicode 对象及规则字节范围。
- 按 TrueType 字形轮廓、度量和绘制位置匹配不同子集。保留语法问题、错映射、缺失映射和无法对齐的不同结果。
- 提供真实 PDFKit `0.17.2` / `0.18.0` 对照、跨子集正反例、独立 PDFium 与 pypdf 验证，以及供 CI 使用的 JSON 和退出码。

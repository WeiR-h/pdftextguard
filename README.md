# PDFTextGuard v0.0.4

在 CI 中比较同一源文档的两次 PDF 导出。页面看起来一样时，复制或搜索的文字仍可能变化。PDFTextGuard 对齐两版实际绘制的字形，比较对应的 ToUnicode 映射，并报告页码、字体对象及具体 CMap 规则。

## 两分钟试用

下载并解压 [v0.0.4 演示包](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.4/PDFTextGuard-v0.0.4.zip)。

在本目录运行。已构建的命令只需 Node.js 22.3 或更新版本，本机验证使用 Node.js 24.13.0。

```powershell
node .\dist\pdftextguard-v0.0.4.cjs --version

# 同一内容用不同字体子集绘制。预期 0，300 个字形成功对齐。
node .\dist\pdftextguard-v0.0.4.cjs check .\verification\fixtures\pdfkit-0.18.0-300.pdf .\verification\fixtures\subset-reordered.pdf

# 文件仍能正常显示，但首个字符的复制结果从 ! 变成 Z。预期 1。
node .\dist\pdftextguard-v0.0.4.cjs check .\verification\fixtures\pdfkit-0.18.0-300.pdf .\verification\fixtures\wrong-unicode.pdf --json
```

CLI 接收两份本地文件，离线、只读运行。也可在 MoonBit 中调用 `check(baseline : Bytes, candidate : Bytes) -> Report`。

| 退出码 | JSON `outcome` | CI 含义 |
| --- | --- | --- |
| `0` | `pass` | 覆盖范围内的用字成功对齐，未发现回归。 |
| `1` | `regression` | 对齐成立，候选出现已用映射变化、缺失或 CMap 语法问题。 |
| `2` | `inconclusive` | 覆盖不完整，包括基线无可靠映射、PDF 结构错误、超出范围及无法可靠对齐。 |

`--json` 输出一份标有 `schema_version: 1` 的 JSON。`aligned_glyphs` 是成功配对的实际绘制次数，`compared_glyphs` 是实际完成语义比较的次数。语法错误中可报告前者，受影响字形的语义比较不计入后者。报告显示最多 80 条诊断，额外条数记在 `diagnostics_omitted`。如有任何无法覆盖的页面，最终退出码为 `2`，已发现的问题仍保留。

映射诊断的 `baseline` 和 `candidate` 分别给出页码、绘制操作、码值、CID、GID、字体与 CMap 对象，以及 Unicode 标量和规则位置。对象带编号和代数。`rule.decoded_offset` 至 `rule.decoded_end` 为解压后 CMap 流的半开字节范围。`value_offset` 进一步指向具体值。页码从 1 开始，所有偏移和数组索引从 0 开始。

## 首版能检查什么

- 适用于同源、页序和绘制顺序稳定的导出。处理横排 `Type0 / Identity-H / CIDFontType2`，读取嵌入静态 TrueType 的 `glyf` 轮廓。支持显式 `CIDToGIDMap` 和 `Identity`。
- MoonBit 经 pdflite 读取传统交叉引用、页面树和对象，逐流追踪 `Tj`、`TJ` 及两种引号绘制操作。支持单次保存、未压缩流和单层 `FlateDecode`，以及继承资源和多条内容流。流边界应落在完整操作之间。
- 用字按同一页的绘制顺序、位置、字形轮廓与度量配对。轮廓解析保留曲线控制点和复合字形结构，跳过字形编号和 hint 指令。对象号、字体资源别名、子集名前缀及 ToUnicode 值不参与对齐。比较采用约 0.01 点的数值容差，重叠且无法区分的字形返回无法确认。
- 严格读取 `codespacerange`、`bfchar` 和 `bfrange` 两种形式，检查声明数量、重复映射及 UTF-16BE 序列。合法的未用字映射变化不会报回归。语法错误另行报告。Unicode 值按原始标量比较，保留连字的多标量映射及补充平面字符。
- 超出覆盖时按退出码 `2` 处理。典型情况包括加密、交叉引用流、增量保存、页面旋转、批注或表单、Form XObject、内联图像、`ActualText`、自定义编码、简单字体、CFF、垂排以及不可对齐的排版变化。上限包括每份 32 MiB、128 页和 100,000 次文本绘制。

这是对显式文本映射的回归检测。整页渲染、阅读顺序、可访问性和作者原意需要各自的验证。PDFium 仅用作独立验证，命令运行时不需要安装 PDFium。

## 实际验证

| 场景 | 观察结果 |
| --- | --- |
| PDFKit #1659 的两个真实版本 | `0.17.2` 用 300 个不同字形，CMap 声明 1 个范围、实际 2 个。`0.18.0` 是 2/2。两份像素相同，PDFium 提取不同。200 个不同字形和重复 300 次 A 的对照正常。 |
| 同源导出更换实际字体子集 | 两份嵌入 FontFile2 散列不同，首个字形 GID 从 1 变为 300。像素和复制文本均相同，检查器对齐 300 个字形、零误报。 |
| 换子集并控制性改错一个映射 | 像素相同，PDFium 的首字符从 `!` 变为 `Z`。检查器报告恰好一处变化，双方内容流操作和 CMap 字节位置由 pypdf 独立核对。 |
| 范围外和保守对齐 | 重叠字形、位置变动、`ActualText` 及加密输入均返回无法确认。更换对象编号和子集前缀、未用映射变化和显式 CID 到 GID 重编码均通过。 |

见 [CLI 验收回执](verification/cli-results.json)、[PDFium 和 pypdf 独立回执](verification/reference-results.json)及 [PDFKit 问题 #1659](https://github.com/foliojs/pdfkit/issues/1659)。真实双版本样本使用未经修改的 PDFKit 包。重新编号子集和改错映射是用于归因的受控变体。

## 安装 MoonBit 库

在你的 MoonBit 项目中添加本版模块，使用 JavaScript 后端运行。

```sh
moon add WeiR-h/pdftextguard@0.0.4
```

在需要调用检查器的包中导入 `WeiR-h/pdftextguard`。见 [Mooncakes API 文档](https://mooncakes.io/docs/WeiR-h/pdftextguard@0.0.4/)。

## 从源码构建与复跑

在源码目录运行。构建脚本按 [依赖锁](scripts/mooncakes-lock.json)校验官方 Mooncakes 源包。首次构建需要可访问 Mooncakes 的网络，已准备本地包时可加 `-Offline`。项目实测工具链为 `moon 0.1.20261104` 和 `moonc v0.10.20+65efd5b93`。

```powershell
.\scripts\build.ps1 -Test
node .\verification\smoke.cjs
```

重新生成样本并验证图像和文本时才需要 npm 与 Python。可用 [requirements.txt](verification/requirements.txt) 在测试环境安装固定版本。

```powershell
npm ci --prefix .\verification\pdfkit --ignore-scripts
node .\verification\pdfkit\generate.cjs
python .\verification\mutate_fixtures.py
node .\verification\smoke.cjs
python .\verification\verify_reference.py
```

版本从 `v0.0.1` 开始，后续按 `v0.0.x` 递增。更新 `moon.mod`、`model.mbt` 和 [CHANGELOG](CHANGELOG.md) 后重新构建。打包前用 `python .\scripts\package_release.py` 对账测试回执和可执行文件散列。

查看 [第三方组件及许可](THIRD_PARTY.md)。

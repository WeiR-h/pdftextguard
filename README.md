# PDFTextGuard v0.0.14

在 CI 中比较同一源文档的两次 PDF 导出。页面看起来一样时，复制或搜索的文字仍可能变化。PDFTextGuard 对齐两版实际绘制的字形，比较对应的 ToUnicode 映射，并报告页码、字体对象及具体 CMap 规则。

评审一页纸汇总本版下载、真实导出对照、错误定位和 MoonBit 复跑步骤。[评审一页纸](REVIEW.md)

## 两分钟试用

下载并解压 v0.0.14 演示包，在解压目录运行 `node verification/demo.cjs`。三组样本依次展示正常换子集、真实 PDFKit 回归和范围外输入。[演示包](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.14/PDFTextGuard-v0.0.14.zip) · [SHA-256](https://github.com/WeiR-h/pdftextguard/releases/download/v0.0.14/SHA256SUMS)

在本目录运行。已构建的命令只需 Node.js 22.3 或更新版本，本机验证使用 Node.js 24.13.0。

```sh
node dist/pdftextguard-v0.0.14.cjs --version

# 同一内容用不同字体子集绘制。预期 0，300 个字形成功对齐。
node dist/pdftextguard-v0.0.14.cjs check verification/fixtures/pdfkit-0.18.0-300.pdf verification/fixtures/subset-reordered.pdf

# 文件仍能正常显示，但首个字符的复制结果从 ! 变成 Z。预期 1。
node dist/pdftextguard-v0.0.14.cjs check verification/fixtures/pdfkit-0.18.0-300.pdf verification/fixtures/wrong-unicode.pdf --json

# 已确认只有绘制顺序变化时，按唯一位置检查映射。这个例子仍会报告一处回归。
node dist/pdftextguard-v0.0.14.cjs check verification/fixtures/pdfkit-0.18.0-300.pdf verification/fixtures/draws-reordered-wrong.pdf --json --align-by-position
```

CLI 在本地离线比较两份 PDF。MoonBit 提供 `check(baseline : Bytes, candidate : Bytes) -> Report` 和 `check_by_position`。默认要求绘制顺序一致。选择 `--align-by-position` 后，只在所有字形均能按形状和位置唯一配对时继续。JSON 的 `position_aligned_pages` 记录用这种方法重新配对的页数。

| 退出码 | JSON `outcome` | CI 含义 |
| --- | --- | --- |
| `0` | `pass` | 覆盖范围内的用字成功对齐，未发现回归。 |
| `1` | `regression` | 对齐成立，候选出现已用映射变化、缺失或 CMap 语法问题。 |
| `2` | `inconclusive` | 覆盖不完整，包括基线无可靠映射、PDF 结构错误、超出范围及无法可靠对齐。 |

`--json` 输出一份标有 `schema_version: 1` 的 JSON。`aligned_glyphs` 是成功配对的实际绘制次数，`compared_glyphs` 是实际完成语义比较的次数。语法错误中可报告前者，受影响字形的语义比较不计入后者。报告显示最多 80 条诊断，额外条数记在 `diagnostics_omitted`。如有任何无法覆盖的页面，最终退出码为 `2`，已发现的问题仍保留。

`page_results` 逐页记录结论、字形计数、映射变化数和去重后的原因码。明细截断后，页级计数和原因仍完整。成功配对的空白页标记为 `no_text`。文件打不开或页数不同时，查看文档级诊断。

映射诊断的 `baseline` 和 `candidate` 分别给出页码、绘制操作、码值、CID、GID、字体与 CMap 对象，以及 Unicode 标量和规则位置。对象带编号和代数。`rule.decoded_offset` 至 `rule.decoded_end` 为解压后 CMap 流的半开字节范围。`value_offset` 进一步指向具体值。嵌套表单用 `form_path` 给出每一层 `Do` 的资源名、对象和偏移。`origin_x/y` 保留原 PDF 页坐标，`display_origin_x/y` 在发生归一化时另报相对有效裁切区域左下角的显示坐标。页码从 1 开始，偏移和数组索引从 0 开始。

```sh
node dist/pdftextguard-v0.0.14.cjs check baseline.pdf candidate.pdf --json --markdown-report "核对报告.md"
```

这条命令同时输出 JSON 和 Markdown。Markdown 记录实际读入文件的 SHA-256，以及页码、字体和 ToUnicode 对象、解码后规则字节范围、两版 Unicode 值或无法确认的原因。目标应是所在目录已经存在的新文件。目标已存在或写入失败时，输出侧别为 `report` 的 `input_error` 并返回 `2`。

## 接入 PDF 导出 CI

把门禁步骤接在你的两版导出之后。使用 `WeiR-h/pdftextguard@v0.0.14` 并传入 `baseline` 和 `candidate`。Action 校验同版本发布包的 SHA-256，然后在运行器上比较两份本地文件。它提供 `report-path`、`outcome` 和 `exit-code`。设置 `markdown-report: 'true'` 后，也提供 `markdown-path`。退出码 `1` 或 `2` 会阻断任务，模板仍会上传已生成的报告。[GitHub Actions 模板](examples/pdf-export-gate.yml)

## 批量检查 PDF 导出

发行包内的示例清单包含通过、回归、无法确认各一组。在解压目录运行。

```sh
node verification/suite.cjs examples/fixture-pairs.json suite-reports --markdown
```

清单使用 UTF-8 JSON，结构如下。

```json
{
  "schema_version": 1,
  "pairs": [
    {"id": "invoice", "baseline": "before/invoice.pdf", "candidate": "after/invoice.pdf"}
  ]
}
```

每组 `id` 唯一。相对 PDF 路径从清单所在目录起算，也可使用绝对路径。输出目录须是尚未创建的新路径。检查按清单顺序运行，逐组 JSON 沿用单对报告格式，汇总写入 `summary.json`。加 `--markdown` 可同时生成逐组 `pair-*.md` 和 `summary.md`。有无法确认的输入时返回 `2`，其余情况有回归返回 `1`，全部通过返回 `0`。样例的汇总退出码是 `2`，三个报告都会保存。清单或写入出错时在标准错误中说明原因，汇总 JSON 在全批完成后写出。

在 Action 中用 `pairs-file` 传入清单，作为单对参数 `baseline` 和 `candidate` 的替代。一次安装即可复用同一发行包检查所有 PDF。报告目录创建后立即通过 `report-dir` 返回，供调用方在任务失败时上传。发生执行错误时保留已完成的逐组报告。目录仍可写时，`execution-error.json` 记录失败阶段、清单项和已完成组数。全批完成后，`report-path` 指向汇总 JSON，`markdown-path` 在启用 Markdown 时指向汇总 Markdown。[批量 Action 模板](examples/pdf-export-suite.yml) · [可运行样例清单](examples/fixture-pairs.json)

## 支持范围

- 适用于同源、页序稳定的导出。处理横排 `Type0 / Identity-H / CIDFontType2`，读取嵌入静态 TrueType 的 `glyf` 轮廓。支持显式 `CIDToGIDMap` 和 `Identity`。
- MoonBit 经 pdflite 读取传统交叉引用、页面树和对象，逐流追踪 `Tj`、`TJ` 及两种引号绘制操作。单次保存的文档还支持未压缩或单层 `FlateDecode` 的交叉引用流和对象流。交叉引用流支持 QPDF 12.4.1 写出的 `Predictor 12`（PNG Up），要求列宽等于索引项宽度，且每行长度和过滤器类型均符合声明。支持继承资源和多条内容流，流边界应落在完整操作之间。
- 用字按页面位置、字形轮廓与度量配对。支持嵌套 Form XObject 的局部资源和矩阵，以及 90°、180° 和 270° 等合法页面旋转。轮廓解析保留曲线控制点和复合字形结构，跳过字形编号和 hint 指令。对象号、字体资源别名、子集名前缀及 ToUnicode 值不参与对齐。比较采用约 0.01 点的数值容差，重叠或无法唯一配对的字形返回无法确认。
- 严格读取 `codespacerange`、`bfchar` 和 `bfrange` 两种形式，检查声明数量、重复映射及 UTF-16BE 序列。合法的未用字映射变化不会报回归。语法错误另行报告。Unicode 值按原始标量比较，保留连字的多标量映射及补充平面字符。
- 超出覆盖时按退出码 `2` 处理。典型情况包括加密、增量保存、混合交叉引用、带预测器的对象流、采用其他预测器的交叉引用流、批注或交互表单、循环或外部 Form、软蒙版、内联图像、`ActualText`、自定义编码、简单字体、CFF、垂排以及不可对齐的排版变化。为避免阅读器差异，两版的 `UserUnit` 必须一致。上限包括每份 32 MiB、50,000 个对象、128 页和 100,000 次文本绘制。

检查范围是文字绘制操作和显式映射。整页渲染、裁切后的可见性、阅读顺序、可访问性和作者原意需要各自的验证。PDFium 仅用作独立验证，命令运行时不需要安装 PDFium。几何规则参考 [ISO 32000-1 §7.7.3、§8.10](https://opensource.adobe.com/dc-acrobat-sdk-docs/standards/pdfstandards/pdf/PDF32000_2008.pdf)。

## 实际验证

| 场景 | 观察结果 |
| --- | --- |
| PDFKit #1659 的两个真实版本 | `0.17.2` 用 300 个不同字形，CMap 声明 1 个范围、实际 2 个。`0.18.0` 是 2/2。两份像素相同，PDFium 提取不同。200 个不同字形和重复 300 次 A 的对照正常。 |
| 同源导出更换实际字体子集 | 两份嵌入 FontFile2 散列不同，首个字形 GID 从 1 变为 300。像素和复制文本均相同，检查器对齐 300 个字形、零误报。 |
| 换子集并控制性改错一个映射 | 像素相同，PDFium 的首字符从 `!` 变为 `Z`。检查器报告恰好一处变化，双方内容流操作和 CMap 字节位置由 pypdf 独立核对。 |
| 范围外和保守对齐 | 重叠字形、位置变动、`ActualText` 及加密输入均返回无法确认。更换对象编号和子集前缀、未用映射变化和显式 CID 到 GID 重编码均通过。 |
| 嵌套表单、旋转和绘制重排 | 独立验证确认测试对中的像素一致，并复核两层表单调用的字节位置。保守模式拒绝画序变化，选择按位置后可以发现同位置的错映射。 |
| PDFBox 3.0.4 的两种真实保存方式 | PDFium 渲染与提取一致，PDFTextGuard 对齐并检查 38 次绘制。受控变体只把 `!` 映射为 `Z`，像素保持一致，报告定位到一条规则。 |
| QPDF 12.4.1 转存为压缩交叉引用流 | 正常转存对齐并检查 300 次绘制。同样转存已含受控错映射的 PDF，仍定位到一处 `!` 到 `Z`，两份页面像素相同。列宽、行长度和行过滤器异常的三个对照都返回 `2`。 |

见 [CLI 验收回执](verification/cli-results.json)、[PDFium 和 pypdf 独立回执](verification/reference-results.json)及 [PDFKit 问题 #1659](https://github.com/foliojs/pdfkit/issues/1659)。真实双版本样本使用未经修改的 PDFKit 包。重新编号子集和改错映射是用于归因的受控变体。

首版到 `v0.0.5`，48 页共享字体样本的端到端中位耗时从 987.33 ms 降至 279.72 ms。本版以 `v0.0.11` 为基线，核对单页和 48 页样本的中位耗时。[性能记录与复跑](PERFORMANCE.md)

## 安装 MoonBit 库

在你的 MoonBit 项目中添加本版模块，使用 JavaScript 后端运行。

```sh
moon add WeiR-h/pdftextguard@0.0.14
```

在 MoonBit 中直接调用 `check` 即可获取结构化报告。独立示例从 Mooncakes 安装本版，并用四份真实或受控候选 PDF 展示三种返回结果。[可运行的 MoonBit 示例](examples/moonbit-consumer/README.md) · [Mooncakes API 文档](https://mooncakes.io/docs/WeiR-h/pdftextguard@0.0.14/)

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
python .\verification\geometry_fixtures.py
node .\verification\smoke.cjs
python .\verification\verify_reference.py
```

如需重建随仓库提供的 QPDF 样本，运行 `python verification/qpdf/generate_fixtures.py <QPDF-12.4.1-可执行文件路径>`。正常样本和错映射样本都由 QPDF 转存。其中错映射来自预先构造的输入 PDF。[QPDF 12.4.1](https://github.com/qpdf/qpdf/releases/tag/v12.4.1) · [样本来源与散列](verification/fixtures/qpdf.json)

准备发行版时，同步模块、CLI、独立示例和更新记录的版本。安装验证工具后运行以下命令。它执行源码构建、MoonBit 测试、CLI 和库示例复跑、独立 PDF 核对及两组性能测试，再打包绑定相同 SHA-256 的证据。

```powershell
python -m pip install -r verification/requirements.txt
python scripts/verify_release.py
```

工具链未在 PATH 时可加 `--moon <moon 可执行文件路径>`，依赖源包和基线 CLI 均已缓存时可加 `--offline`。[版本更新记录](CHANGELOG.md) · [本版验证回执](verification/acceptance-results.json)

查看 [第三方组件及许可](THIRD_PARTY.md)。

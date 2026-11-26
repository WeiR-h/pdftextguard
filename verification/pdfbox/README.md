# Apache PDFBox 复跑

两份真实输出由同一个 Java 源码使用 Apache PDFBox 3.0.4 保存。ZIP 已带样本，复跑检查器只需 Node。重新生成时准备 JDK 和四个 Maven Central JAR，版本和实际 SHA-256 见 [样本清单](../fixtures/pdfbox.json)。

```powershell
java --class-path ".work/pdfbox/*" verification/pdfbox/Fixture.java .work/pdfbox verification/assets/LiberationSans-Regular.ttf
python verification/pdfbox/install_fixtures.py .work/pdfbox
```

先在 `.work/pdfbox` 放好校验过的 JAR。传统和压缩保存的共同文本为 `! PDFTextGuard compares exported text.`。错映射变体从压缩版修改一条 ToUnicode 规则。结构控制修改交叉引用流的声明，用于检查增量、混合结构和对象限额的拒绝路径。

## 两页中英报价单

报价单使用合成数据和 [霞鹜文楷 v1.510](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.510)。[样本清单](../fixtures/quote.json)记录字体、生成源码、许可及四份 PDF 的 SHA-256。普通和压缩导出调用同一份 Java 源码，受控样本改写第 2 页的一个显式 ToUnicode 映射，加密对照由 PDFBox 生成。ZIP 提供 PDF 内嵌字体子集及许可，原始 TTF 仅在重建时获取。

重建验证使用 JDK 25、上面的四个 JAR 及清单指定的 TTF。命令在临时目录生成样本并核对字节。

```sh
python verification/pdfbox/generate_quote.py .work/pdfbox LXGWWenKai-Regular.ttf
node verification/quote_demo.cjs
```

# Apache PDFBox 复跑

两份真实输出由同一个 Java 源码使用 Apache PDFBox 3.0.4 保存。ZIP 已带样本，复跑检查器只需 Node。重新生成时准备 JDK 和四个 Maven Central JAR，版本和实际 SHA-256 见 [样本清单](../fixtures/pdfbox.json)。

```powershell
java --class-path ".work/pdfbox/*" verification/pdfbox/Fixture.java .work/pdfbox verification/assets/LiberationSans-Regular.ttf
python verification/pdfbox/install_fixtures.py .work/pdfbox
```

先在 `.work/pdfbox` 放好校验过的 JAR。传统和压缩保存的共同文本为 `! PDFTextGuard compares exported text.`。错映射变体从压缩版修改一条 ToUnicode 规则。结构控制修改交叉引用流的声明，用于检查增量、混合结构和对象限额的拒绝路径。

"""Render the captioned 90-second review demo from the public fixtures."""

import argparse
import json
from pathlib import Path
import re
import subprocess

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps
from pypdfium2 import PdfDocument


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "verification/fixtures"
CREAM = "#f5f3ec"
INK = "#172b27"
TEAL = "#087d68"


def excerpt(name):
    document = PdfDocument(FIXTURES / name)
    page = document[0]
    bitmap = page.render(scale=1.8)
    image = bitmap.to_pil().convert("RGB").copy()
    bitmap.close()
    page.close()
    document.close()
    bbox = ImageChops.difference(image, Image.new("RGB", image.size, "white")).getbbox()
    return ImageOps.contain(image.crop(bbox), (504, 238), method=Image.Resampling.LANCZOS)


def render(tag, work, font_file):
    font = lambda size: ImageFont.truetype(str(font_file), size=size)
    proof = json.loads((ROOT / "verification/reference-results.json").read_text(encoding="utf-8"))
    assert "v" + proof["toolVersion"] == tag
    report = proof["pdfbox"]["verified_changed_rule"]
    old = excerpt("pdfkit-0.17.2-300.pdf")
    current = excerpt("pdfkit-0.18.0-300.pdf")
    assert old.tobytes() == current.tobytes()
    pdfbox = excerpt("pdfbox-compressed.pdf")
    assert pdfbox.tobytes() == excerpt("pdfbox-wrong-unicode.pdf").tobytes()

    def slide(number, title, duration, body, images=()):
        image = Image.new("RGB", (1280, 720), CREAM)
        d = ImageDraw.Draw(image)
        d.rectangle((0, 0, 1280, 13), fill=TEAL)
        d.text((64, 40), "PDFTextGuard " + tag, font=font(24), fill=TEAL)
        d.text((64, 91), title, font=font(52), fill=INK)
        top = 205
        for line in body:
            d.text((66, top), line, font=font(29), fill=INK)
            top += 52
        if images:
            for index, (label, crop) in enumerate(images):
                x = 66 + index * 583
                d.rounded_rectangle((x, 348, x + 549, 640), 17, fill="white", outline="#d8ded8", width=2)
                d.text((x + 18, 360), label, font=font(23), fill=TEAL)
                image.paste(crop, (x + 20, 400))
        for progress in range(6):
            x = 66 + progress * 192
            d.rounded_rectangle((x, 668, x + 180, 675), 4, fill=TEAL if progress <= number else "#ccd5ce")
        path = work / f"scene-{number}.png"
        image.save(path)
        return path, duration

    return [
        slide(0, "页面一样，复制出来的字呢？", 10, [
            "PDF 生成器升级后，渲染快照可以完全一致。",
            "文字层里的 Unicode 映射仍可能改变，影响复制、搜索和索引。",
            "PDFTextGuard 检查同一源文档的两次导出，并给出可复核的位置。",
        ]),
        slide(1, "真实回归 · PDFKit #1659", 16, [
            "PDFium 验证两份输出像素一致，提取文字不同。",
            "第一页 ToUnicode 17 0 R 的规则声明 1 个范围，实际有 2 个。",
        ], [("旧版 0.17.2", old), ("修复版 0.18.0", current)]),
        slide(2, "一个命令，复跑三种结果", 18, [
            "node verification/demo.cjs",
            "0  正常换子集 · 检查 300 次绘制",
            "1  真实 PDFKit 回归 · beginbfrange 字节 243–257",
            "2  加密输入 · 无法确认，门禁阻断",
        ]),
        slide(3, "第二种导出 · PDFBox 3.0.4", 19, [
            "同一 Java 源文档，两种真实保存方式通过门禁。",
            f"受控错映射 ! → Z · 第 1 页 · ToUnicode 字节 {report['decoded_offset']}–{report['decoded_end']}",
        ], [("默认压缩保存", pdfbox), ("受控错映射 · 像素一致", pdfbox)]),
        slide(4, "接到 PDF 导出 CI", 15, [
            "提交同源的基线与候选文件，检查器输出 JSON 定位报告。",
            "0 放行。遇到回归或无法确认时，保留报告并阻断任务。",
            "公开发布包由 GitHub Actions 从空环境下载、校验和复跑。",
        ]),
        slide(5, "下载演示包，自己复跑", 12, [
            "github.com/WeiR-h/pdftextguard",
            f"发布版本 {tag} · SHA-256 · CLI · 源码 · 独立核对记录",
            "Mooncakes 库 WeiR-h/pdftextguard",
        ]),
    ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    args = parser.parse_args()
    tag = "v" + re.search(r'^version = "([^"]+)"', (ROOT / "moon.mod").read_text(), re.M)[1]
    work = ROOT / ".work/demo-scenes"
    work.mkdir(parents=True, exist_ok=True)
    scenes = render(tag, work, args.font)
    manifest = work / "scenes.txt"
    manifest.write_text("".join(f"file '{file.name}'\nduration {seconds}\n" for file, seconds in scenes)
                        + f"file '{scenes[-1][0].name}'\n", encoding="ascii", newline="\n")
    assert sum(duration for _, duration in scenes) == 90
    output = ROOT / "dist" / f"PDFTextGuard-{tag}-demo.mp4"
    subprocess.run([str(args.ffmpeg.resolve()), "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "concat", "-safe", "1", "-i", str(manifest), "-t", "90", "-r", "24",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(output)], check=True)
    print(output)


if __name__ == "__main__":
    main()

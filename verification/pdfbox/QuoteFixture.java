import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.TimeZone;
import java.util.regex.Pattern;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.encryption.AccessPermission;
import org.apache.pdfbox.pdmodel.encryption.StandardProtectionPolicy;
import org.apache.pdfbox.pdmodel.font.PDType0Font;
import org.apache.pdfbox.pdfwriter.compress.CompressParameters;

class QuoteFixture {
    public static void main(String[] args) throws Exception {
        File output = new File(args[0]);
        File font = new File(args[1]);
        File compressed = new File(output, "quote-compressed.pdf");
        export(new File(output, "quote-classic.pdf"), font, CompressParameters.NO_COMPRESSION);
        export(compressed, font, CompressParameters.DEFAULT_COMPRESSION);
        changeMapping(compressed, new File(output, "quote-wrong-unicode.pdf"));
        encrypt(compressed, new File(output, "quote-encrypted.pdf"));
    }

    private static void export(File file, File fontFile, CompressParameters compression) throws Exception {
        try (PDDocument doc = new PDDocument()) {
            Calendar stamp = new GregorianCalendar(TimeZone.getTimeZone("UTC"));
            stamp.clear();
            stamp.set(2026, Calendar.NOVEMBER, 26);
            doc.getDocumentInformation().setCreationDate(stamp);
            doc.getDocumentInformation().setTitle("PDFTextGuard synthetic quote");
            doc.setDocumentId(20261126L);
            PDType0Font font = PDType0Font.load(doc, fontFile);

            PDPage items = new PDPage();
            doc.addPage(items);
            try (PDPageContentStream content = new PDPageContentStream(doc, items)) {
                text(content, font, 60, 714, 28, "项目报价单");
                text(content, font, 61, 681, 14, "QUOTATION   /   SAMPLE 26-01");
                line(content, 655);
                text(content, font, 61, 623, 17, "设备及服务   Items");
                text(content, font, 61, 575, 13, "名称 Item");
                text(content, font, 327, 575, 13, "数量 Qty");
                text(content, font, 450, 575, 13, "金额 CNY");
                line(content, 554);
                text(content, font, 61, 521, 15, "终端控制器");
                text(content, font, 327, 521, 15, "2 件");
                text(content, font, 450, 521, 15, "840.00");
                text(content, font, 61, 480, 15, "温度传感器");
                text(content, font, 327, 480, 15, "4 件");
                text(content, font, 450, 480, 15, "520.00");
                text(content, font, 61, 439, 15, "安装服务");
                text(content, font, 327, 439, 15, "1 项");
                text(content, font, 450, 439, 15, "320.00");
                line(content, 414);
                footer(content, font, "01 / 02");
            }

            PDPage totals = new PDPage();
            doc.addPage(totals);
            try (PDPageContentStream content = new PDPageContentStream(doc, totals)) {
                text(content, font, 60, 714, 28, "核对明细");
                text(content, font, 61, 681, 14, "REVIEW   /   SAMPLE 26-01");
                line(content, 655);
                text(content, font, 61, 609, 16, "服务期限   30 天");
                text(content, font, 61, 563, 16, "交付方式   本地部署");
                line(content, 527);
                text(content, font, 61, 479, 20, "合计 Total");
                text(content, font, 419, 479, 20, "CNY 1680.00");
                line(content, 451);
                footer(content, font, "02 / 02");
            }
            doc.save(file, compression);
        }
    }

    private static void text(PDPageContentStream content, PDType0Font font, int x, int y, int size,
                             String value) throws Exception {
        content.beginText();
        content.setFont(font, size);
        content.newLineAtOffset(x, y);
        content.showText(value);
        content.endText();
    }

    private static void line(PDPageContentStream content, int y) throws Exception {
        content.setStrokingColor(0.56f, 0.63f, 0.69f);
        content.setLineWidth(0.6f);
        content.moveTo(60, y);
        content.lineTo(552, y);
        content.stroke();
    }

    private static void footer(PDPageContentStream content, PDType0Font font, String page) throws Exception {
        line(content, 100);
        text(content, font, 61, 76, 11, "PDFTextGuard 演示数据");
        text(content, font, 487, 76, 11, page);
    }

    private static void changeMapping(File original, File variant) throws Exception {
        try (PDDocument doc = Loader.loadPDF(original)) {
            var resources = doc.getPage(1).getResources();
            var font = resources.getFont(resources.getFontNames().iterator().next());
            var cmap = font.getCOSObject().getCOSStream(COSName.TO_UNICODE);
            String text;
            try (var source = cmap.createInputStream()) {
                text = new String(source.readAllBytes(), StandardCharsets.US_ASCII);
            }
            var rule = Pattern.compile(
                "(?m)^(<([0-9A-Fa-f]{4})>[ \\t]+(?:<\\2>[ \\t]+)?)<5408>[ \\t]*$"
            ).matcher(text);
            if (!rule.find()) {
                throw new IllegalStateException("Expected a single explicit mapping to U+5408");
            }
            int start = rule.start(1) + rule.group(1).length();
            if (rule.find()) {
                throw new IllegalStateException("The mapping to U+5408 is ambiguous");
            }
            String changed = text.substring(0, start) + "<53F0>" + text.substring(start + 6);
            try (var output = cmap.createOutputStream(COSName.FLATE_DECODE)) {
                output.write(changed.getBytes(StandardCharsets.US_ASCII));
            }
            doc.save(variant, CompressParameters.DEFAULT_COMPRESSION);
        }
    }

    private static void encrypt(File original, File output) throws Exception {
        try (PDDocument doc = Loader.loadPDF(original)) {
            // The fixed fixture uses the deterministic 128-bit PDF encryption option.
            var policy = new StandardProtectionPolicy("sample-owner", "sample-reader", new AccessPermission());
            policy.setEncryptionKeyLength(128);
            policy.setPreferAES(false);
            doc.protect(policy);
            doc.save(output, CompressParameters.DEFAULT_COMPRESSION);
        }
    }
}

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.TimeZone;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.cos.COSName;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.font.PDType0Font;
import org.apache.pdfbox.pdfwriter.compress.CompressParameters;

class Fixture {
    public static void main(String[] args) throws Exception {
        File output = new File(args[0]);
        File fontFile = new File(args[1]);
        File compressed = new File(output, "pdfbox-compressed.pdf");
        render(new File(output, "pdfbox-classic.pdf"), fontFile, false);
        render(compressed, fontFile, true);
        alterMapping(compressed, new File(output, "pdfbox-wrong-unicode.pdf"));
    }

    private static void render(File file, File fontFile, boolean compress)
            throws Exception {
        try (PDDocument doc = new PDDocument()) {
            Calendar stamp = new GregorianCalendar(TimeZone.getTimeZone("UTC"));
            stamp.clear();
            stamp.set(2026, Calendar.NOVEMBER, 20);
            doc.getDocumentInformation().setCreationDate(stamp);
            doc.setDocumentId(20261120L);
            PDType0Font font = PDType0Font.load(doc, fontFile);
            PDPage page = new PDPage();
            doc.addPage(page);
            try (PDPageContentStream content = new PDPageContentStream(doc, page)) {
                content.beginText();
                content.setFont(font, 14);
                content.newLineAtOffset(72, 720);
                content.showText("! PDFTextGuard compares exported text.");
                content.endText();
            }
            doc.save(file, compress ? CompressParameters.DEFAULT_COMPRESSION
                                    : CompressParameters.NO_COMPRESSION);
        }
    }

    private static void alterMapping(File original, File variant) throws Exception {
        try (PDDocument doc = Loader.loadPDF(original)) {
            var resources = doc.getPage(0).getResources();
            var font = resources.getFont(resources.getFontNames().iterator().next());
            var cmap = font.getCOSObject().getCOSStream(COSName.TO_UNICODE);
            String text;
            try (var source = cmap.createInputStream()) {
                text = new String(source.readAllBytes(), StandardCharsets.US_ASCII);
            }
            String originalRule = "<0003> <0004> <0020>";
            if (text.indexOf(originalRule) < 0 || text.indexOf(originalRule) != text.lastIndexOf(originalRule)) {
                throw new IllegalStateException("Expected a single space and exclamation mark CMap range");
            }
            String changed = text.replace(originalRule, "<0003> <0004> [<0020> <005A>]");
            try (var output = cmap.createOutputStream(COSName.FLATE_DECODE)) {
                output.write(changed.getBytes(StandardCharsets.US_ASCII));
            }
            doc.save(variant, CompressParameters.DEFAULT_COMPRESSION);
        }
    }
}

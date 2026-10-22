import Foundation
import Testing
import ChikaCore

struct ComicInfoTests {
    @Test func parsesComicRackMetadata() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
            <Title> A New Beginning </Title>
            <Series> Example &amp; Friends </Series>
            <Number> 1.5 </Number>
            <Volume> 2 </Volume>
            <Summary>An adventure.</Summary>
            <Writer> Jane Doe </Writer>
            <Pages><Page Image="0" Type="FrontCover"><Title>Ignored</Title></Page></Pages>
        </ComicInfo>
        """
        #expect(ComicInfo.parse(Data(xml.utf8)) == ComicInfo(
            series: "Example & Friends", volume: "2", number: "1.5", writer: "Jane Doe", title: "A New Beginning"
        ))
    }

    @Test func rejectsMalformedAndEmptyMetadata() {
        for xml in ["garbage", "<ComicInfo><Series>Example</Series>",
                    "<ComicInfo><Summary>Only a summary</Summary></ComicInfo>",
                    "<ComicInfo><Series> \n </Series><Title/></ComicInfo>",
                    "<ComicInfo><series>Wrong case</series><Pages><Series>Nested</Series></Pages></ComicInfo>"] {
            #expect(ComicInfo.parse(Data(xml.utf8)) == nil)
        }
    }

    @Test func preservesOptionalFieldsAndCDATA() {
        #expect(ComicInfo.parse(Data("<ComicInfo><Title><![CDATA[ A & B ]]></Title></ComicInfo>".utf8)) == ComicInfo(title: "A & B"))
    }

    @Test func ordersNumbersNaturallyAndVolumesFirst() {
        #expect(ComicInfo.issueOrder(ComicInfo(number: "2"), ComicInfo(number: "10")))
        #expect(ComicInfo.issueOrder(ComicInfo(number: "1"), ComicInfo(number: "1.5")))
        #expect(ComicInfo.issueOrder(ComicInfo(number: "1.5"), ComicInfo(number: "2")))
        #expect(ComicInfo.issueOrder(ComicInfo(volume: "2", number: "10"), ComicInfo(volume: "10", number: "1")))
        #expect(ComicInfo.issueOrder(ComicInfo(number: "10"), ComicInfo(volume: "1", number: "1")))
        #expect(ComicInfo.issueOrder(ComicInfo(volume: "1"), ComicInfo(volume: "1", number: "1")))
        #expect(!ComicInfo.issueOrder(ComicInfo(number: "2"), ComicInfo(number: "02")))
    }

    @Test func findsNextIssueInTheSameSeries() {
        let candidates = [
            ComicInfo(series: "Example", number: "10"),
            ComicInfo(series: "Other", number: "2"),
            ComicInfo(series: "EXAMPLE", number: "2"),
            ComicInfo(series: "Example", number: "1"),
            ComicInfo(number: "2"),
        ]
        #expect(ComicInfo.next(after: ComicInfo(series: "Example", number: "1"), in: candidates) == 2)
        #expect(ComicInfo.next(after: candidates[0], in: candidates) == nil)
        #expect(ComicInfo.next(after: ComicInfo(number: "1"), in: candidates) == nil)
    }
}

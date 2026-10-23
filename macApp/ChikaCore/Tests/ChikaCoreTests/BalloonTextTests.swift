import Testing
import ChikaCore

struct BalloonTextTests {
    @Test func cropGrowsTheBalloonAndStaysOnThePage() {
        let crop = BalloonText.cropRect(Panel(0.2, 0.4, 0.4, 0.6), pad: 0.1)
        near(0.18, crop.left, 0.0001); near(0.38, crop.top, 0.0001)
        near(0.42, crop.right, 0.0001); near(0.62, crop.bottom, 0.0001)
        let edge = BalloonText.cropRect(Panel(0, 0.9, 1, 1))
        #expect(edge.left == 0 && edge.right == 1 && edge.bottom == 1)
        near(0.896, edge.top, 0.0001)
    }

    @Test func verticalColumnsReadRightToLeftWithoutSpaces() {
        let lines = [(box: Panel(0.1, 0.1, 0.3, 0.9), text: "どこへ"),
                     (box: Panel(0.6, 0.1, 0.8, 0.9), text: "今日は "),
                     (box: Panel(0.35, 0.1, 0.55, 0.5), text: "いい")]
        #expect(BalloonText.join(lines) == "今日はいいどこへ")
    }

    @Test func horizontalLinesReadTopToBottomWithSpaces() {
        let lines = [(box: Panel(0.1, 0.6, 0.9, 0.8), text: "you are"),
                     (box: Panel(0.1, 0.2, 0.9, 0.4), text: "Where"),
                     (box: Panel(0.1, 0.85, 0.9, 0.95), text: " ")]
        #expect(BalloonText.join(lines) == "Where you are")
        #expect(BalloonText.join([]) == "")
    }

    @Test func onlyTextWithLettersIsTranslated() {
        #expect(BalloonText.isWorthTranslating("なに!?"))
        #expect(!BalloonText.isWorthTranslating("!? …"))
        #expect(!BalloonText.isWorthTranslating(""))
    }

    @Test func sameLanguageIgnoresRegionButNotScript() {
        #expect(BalloonText.sameLanguage("en", "en-GB"))
        #expect(BalloonText.sameLanguage("ja", "ja-JP"))
        #expect(!BalloonText.sameLanguage("ja", "en"))
        #expect(!BalloonText.sameLanguage("zh-Hans", "zh-Hant"))
    }

    @Test func paperIsTheCommonestColourNotTheLettering() {
        let white: [UInt8] = [250, 248, 246, 255], black: [UInt8] = [10, 10, 10, 255]
        let sample = Array(repeating: white, count: 10).flatMap { $0 } + Array(repeating: black, count: 4).flatMap { $0 }
        let paper = BalloonText.paperColor(rgba: sample)
        #expect(paper.r == 250 && paper.g == 248 && paper.b == 246)
        #expect(BalloonText.inkIsDark(on: paper))
        #expect(!BalloonText.inkIsDark(on: BalloonText.paperColor(rgba: black)))
        #expect(BalloonText.paperColor(rgba: []) == (255, 255, 255))
    }
}

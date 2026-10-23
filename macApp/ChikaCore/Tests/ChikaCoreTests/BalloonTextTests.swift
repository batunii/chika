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
        // Anti-aliased lettering edges, in the paper's colour bin too: an average would be grey.
        let edge: [UInt8] = [228, 228, 228, 255], darkEdge: [UInt8] = [28, 28, 30, 255]
        func sample(_ pixels: (pixel: [UInt8], count: Int)...) -> [UInt8] { pixels.flatMap { Array(repeating: $0.pixel, count: $0.count).flatMap { $0 } } }
        let paper = BalloonText.paperColor(rgba: sample((white, 10), (edge, 6), (black, 4)))
        #expect(paper.r == 250 && paper.g == 248 && paper.b == 246)
        #expect(BalloonText.inkIsDark(on: paper))
        let dark = BalloonText.paperColor(rgba: sample((black, 10), (darkEdge, 6), (white, 4)))   // light lettering on dark paper
        #expect(dark.r == 10 && dark.g == 10 && dark.b == 10)
        #expect(!BalloonText.inkIsDark(on: dark))
        #expect(BalloonText.paperColor(rgba: []) == (255, 255, 255))
    }

    @Test func aPageIsOneLanguageUnlessABalloonIsSureOfItsOwn() {
        // Read alone: zh-Hant, pl and de.
        #expect(BalloonText.languages(of: ["今日はいい天気ですね", "どこへ行こうか", "大丈夫", "BAM!", "Hm"]) == ["ja", "ja", "ja", "ja", "ja"])
        #expect(BalloonText.languages(of: ["今日はいい天気ですね", "どこへ行こうか", "明日また会おう", "Where are we going?", "Hm"])
                == ["ja", "ja", "ja", "en", "ja"])
        #expect(BalloonText.languages(of: ["!?"]) == [nil])
        #expect(BalloonText.languages(of: []).isEmpty)
    }

    @Test func eachBalloonIsReadWithTheRegionItOverlapsMost() {
        let top = Panel(0, 0, 1, 0.55), bottom = Panel(0, 0.45, 1, 1)   // padded: they overlap
        let a = Panel(0.1, 0.1, 0.3, 0.3), b = Panel(0.6, 0.1, 0.8, 0.3)
        let straddling = Panel(0.4, 0.4, 0.6, 0.52)   // mostly in the top region
        let low = Panel(0.2, 0.7, 0.4, 0.9)
        #expect(BalloonText.balloons([low, b, straddling, a], inRegion: 0, of: [top, bottom], rightToLeft: false) == [a, b, straddling])
        #expect(BalloonText.balloons([low, b, straddling, a], inRegion: 0, of: [top, bottom], rightToLeft: true) == [b, a, straddling])
        #expect(BalloonText.balloons([low, b, straddling, a], inRegion: 1, of: [top, bottom], rightToLeft: false) == [low])
    }

    @Test func aBalloonOutsideEveryRegionGoesToTheNearestAndWholePageSlotsReadNone() {
        let left = Panel(0, 0, 0.4, 1), right = Panel(0.6, 0, 1, 1)
        let gap = Panel(0.45, 0.4, 0.58, 0.5)   // in the gutter, nearer the right region
        #expect(BalloonText.balloons([gap], inRegion: 1, of: [left, right], rightToLeft: false) == [gap])
        #expect(BalloonText.balloons([gap], inRegion: 0, of: [left, right], rightToLeft: false).isEmpty)
        #expect(BalloonText.balloons([gap], inRegion: -1, of: [left, right], rightToLeft: false).isEmpty)
        #expect(BalloonText.balloons([gap], inRegion: 2, of: [left, right], rightToLeft: false).isEmpty)
        #expect(BalloonText.balloons([gap], inRegion: 0, of: [.fullPage], rightToLeft: false) == [gap])
    }

    @Test func aWholePageReadsPanelByPanel() {
        // A tall left panel (A over B) beside two stacked right panels (C, D): row order would be A, C, B, D.
        let tall = Panel(0, 0, 0.5, 1), upper = Panel(0.5, 0, 1, 0.5), lower = Panel(0.5, 0.5, 1, 1)
        let a = Panel(0.1, 0.1, 0.3, 0.2), b = Panel(0.1, 0.6, 0.3, 0.7), c = Panel(0.6, 0.15, 0.9, 0.25), d = Panel(0.6, 0.65, 0.9, 0.75)
        #expect(BalloonText.balloons([d, c, b, a], of: [tall, upper, lower], rightToLeft: false) == [a, b, c, d])
        #expect(BalloonText.balloons([d, c, b, a], of: [], rightToLeft: false) == [a, c, b, d])   // no panels: the whole page
    }
}

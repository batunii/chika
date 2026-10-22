import Testing
import ChikaCore

struct YoloLabelTests {
    @Test func formatsCenterAndSizeLikeTheTrainingScripts() {
        #expect(Panel(0.25, 0.25, 0.75, 0.5).yoloLabel == "0 0.500000 0.375000 0.500000 0.250000")
        #expect(Panel.fullPage.yoloLabel == "0 0.500000 0.500000 1.000000 1.000000")
    }

    @Test func clampsToThePageAndDropsDegenerateBoxes() {
        #expect(Panel(-0.5, 0, 0.5, 1.5).yoloLabel == "0 0.250000 0.500000 0.500000 1.000000")
        #expect(Panel(0.5, 0.2, 0.5, 0.8).yoloLabel == nil)
        #expect(Panel(1.1, 0, 1.5, 1).yoloLabel == nil)
        #expect(Panel(0.6, 0.6, 0.4, 0.4).yoloLabel == nil)
    }
}

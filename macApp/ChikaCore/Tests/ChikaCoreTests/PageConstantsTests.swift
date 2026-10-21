import Testing
import ChikaCore

struct PageConstantsTests {
    @Test(arguments: [(2559, 1), (2560, 1), (2561, 1), (5120, 2), (5121, 2)])
    func inSampleSizeKeepsLongEdgeAtOrAboveMax(longEdge: Int, expected: Int) {
        #expect(computeInSampleSize(longEdge: longEdge, maxDim: PageConstants.maxPageDimension) == expected)
    }
}

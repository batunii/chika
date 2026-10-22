import Foundation

/// The ComicRack ComicInfo.xml fields the library groups and orders by.
public struct ComicInfo: Equatable, Sendable {
    /// The entry name readers look for (matched case-insensitively, at any folder depth).
    public static func isEntry(_ name: String) -> Bool {
        (name as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
    }

    public var series: String?
    public var volume: String?
    public var number: String?
    public var writer: String?
    public var title: String?

    public init(series: String? = nil, volume: String? = nil, number: String? = nil, writer: String? = nil, title: String? = nil) {
        self.series = series
        self.volume = volume
        self.number = number
        self.writer = writer
        self.title = title
    }

    public static func parse(_ data: Data) -> ComicInfo? {
        let delegate = ComicInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.hasComicInfoRoot, delegate.info != ComicInfo() else { return nil }
        return delegate.info
    }

    public static func issueOrder(_ a: ComicInfo, _ b: ComicInfo) -> Bool {
        for (left, right) in [(a.volume, b.volume), (a.number, b.number)] {
            switch (left, right) {
            case (nil, nil): continue
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?):
                let comparison = NaturalOrder.compare(left, right)
                if comparison != 0 { return comparison < 0 }
            }
        }
        return false
    }

    public static func next(after current: ComicInfo, in candidates: [ComicInfo]) -> Int? {
        guard let series = current.series else { return nil }
        var nextIndex: Int?
        for (index, candidate) in candidates.enumerated() {
            guard let candidateSeries = candidate.series,
                  series.caseInsensitiveCompare(candidateSeries) == .orderedSame,
                  issueOrder(current, candidate) else { continue }
            if let best = nextIndex {
                if issueOrder(candidate, candidates[best]) { nextIndex = index }
            } else {
                nextIndex = index
            }
        }
        return nextIndex
    }
}

private final class ComicInfoParser: NSObject, XMLParserDelegate {
    var info = ComicInfo()
    var hasComicInfoRoot = false
    private var depth = 0
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        if depth == 1 { hasComicInfoRoot = elementName == "ComicInfo" }
        if depth == 2 { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth == 2 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if depth == 2 { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if depth == 2 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String? = trimmed.isEmpty ? nil : trimmed
            switch elementName {
            case "Series": info.series = value
            case "Volume": info.volume = value
            case "Number": info.number = value
            case "Writer": info.writer = value
            case "Title": info.title = value
            default: break
            }
        }
        depth -= 1
    }
}

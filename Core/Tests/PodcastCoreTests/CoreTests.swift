import XCTest
@testable import PodcastCore

final class RSSParserTests: XCTestCase {
    let feedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
    <channel>
      <title>Test Show</title>
      <itunes:author>Jane Host</itunes:author>
      <description><![CDATA[A show about <b>tests</b>.]]></description>
      <itunes:image href="https://example.com/art.jpg"/>
      <itunes:category text="Technology"><itunes:category text="Software How-To"/></itunes:category>
      <image><url>https://example.com/fallback.jpg</url><title>Test Show</title></image>
      <item>
        <title>Episode Two</title>
        <guid isPermaLink="false">ep-2</guid>
        <pubDate>Tue, 03 Nov 2026 10:00:00 +0000</pubDate>
        <itunes:duration>1:02:03</itunes:duration>
        <description>&lt;p&gt;Notes &amp;amp; links&lt;/p&gt;</description>
        <enclosure url="https://example.com/ep2.mp3?x=1&amp;y=2" length="12345" type="audio/mpeg"/>
        <podcast:transcript url="https://example.com/ep2.html" type="text/html"/>
        <podcast:transcript url="https://example.com/ep2.vtt" type="text/vtt"/>
        <podcast:chapters url="https://example.com/ep2.json" type="application/json+chapters"/>
      </item>
      <item>
        <title>Episode One</title>
        <pubDate>Mon, 02 Nov 2026 10:00:00 GMT</pubDate>
        <itunes:duration>1800</itunes:duration>
        <enclosure url="https://example.com/ep1.mp3" type="audio/mpeg"/>
      </item>
      <item><title>No audio</title></item>
    </channel>
    </rss>
    """

    func testParsesChannelAndEpisodes() throws {
        let feed = try RSSParser.parse(Data(feedXML.utf8))
        XCTAssertEqual(feed.title, "Test Show")
        XCTAssertEqual(feed.author, "Jane Host")
        XCTAssertEqual(feed.artworkURL?.absoluteString, "https://example.com/art.jpg")
        XCTAssertEqual(feed.categories.first, "Technology")
        XCTAssertEqual(feed.episodes.count, 2)

        let two = feed.episodes[0]
        XCTAssertEqual(two.title, "Episode Two")
        XCTAssertEqual(two.guid, "ep-2")
        XCTAssertEqual(two.duration, 3723)
        XCTAssertEqual(two.fileSize, 12345)
        XCTAssertEqual(two.audioURL.absoluteString, "https://example.com/ep2.mp3?x=1&y=2")
        XCTAssertEqual(two.summary, "Notes & links")
        XCTAssertNotNil(two.pubDate)
        XCTAssertEqual(TranscriptParser.bestLink(from: two.transcripts)?.type, "text/vtt")
        XCTAssertEqual(two.chaptersURL?.absoluteString, "https://example.com/ep2.json")

        let one = feed.episodes[1]
        XCTAssertEqual(one.guid, "https://example.com/ep1.mp3")
        XCTAssertEqual(one.duration, 1800)
        XCTAssertNotNil(one.pubDate)
    }

    func testRejectsNonFeed() {
        XCTAssertThrowsError(try RSSParser.parse(Data("<html><body>nope</body></html>".utf8)))
    }
}

final class TranscriptParserTests: XCTestCase {
    func testVTT() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:04.500 align:start
        <v Host>Hello there

        01:05.000 --> 01:08.000
        second
        line
        """
        let segments = TranscriptParser.parse(Data(vtt.utf8), type: "text/vtt")
        XCTAssertEqual(segments, [
            TranscriptSegment(start: 1, end: 4.5, text: "Hello there"),
            TranscriptSegment(start: 65, end: 68, text: "second line"),
        ])
    }

    func testSRT() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n2\n01:00:00,500 --> 01:00:02,000\nBye\n"
        let segments = TranscriptParser.parse(Data(srt.utf8), type: "application/x-subrip")
        XCTAssertEqual(segments?.count, 2)
        XCTAssertEqual(segments?.last?.start, 3600.5)
    }

    func testJSONAndUnsupported() {
        let json = #"{"version":"1.0.0","segments":[{"startTime":0.5,"endTime":2,"body":"Hi"},{"startTime":2,"body":"there"}]}"#
        XCTAssertEqual(TranscriptParser.parse(Data(json.utf8), type: "application/json")?.count, 2)
        XCTAssertNil(TranscriptParser.parse(Data("plain".utf8), type: "text/plain"))
    }

    func testChapters() {
        let json = #"{"version":"1.2.0","chapters":[{"startTime":60,"title":"Sponsor: Acme"},{"startTime":0,"title":"Intro"}]}"#
        XCTAssertEqual(TranscriptParser.parseChapters(Data(json.utf8)).map(\.title), ["Intro", "Sponsor: Acme"])
    }
}

final class AdDetectorTests: XCTestCase {
    /// Spreads sentences over time as word-level segments, like a speech recogniser.
    func words(_ text: String, from start: TimeInterval, wordsPerSecond: Double = 2.5) -> [TranscriptSegment] {
        text.split(separator: " ").enumerated().map { index, word in
            let time = start + Double(index) / wordsPerSecond
            return TranscriptSegment(start: time, end: time + 0.3, text: String(word))
        }
    }

    let content = """
    so when we looked at the data from the nineteen seventies what really stood out was how quickly the \
    population of the city changed and my grandmother used to tell this story about the river flooding \
    every spring and how the whole neighborhood would come together to move furniture upstairs and I think \
    that sense of community is what the author is really trying to capture in the third chapter of the book \
    which honestly surprised me because the first two chapters are so focused on the economics of it all \
    and then you get this very personal turn where she starts interviewing people who lived through it \
    and the historians we spoke to said the archive had been sitting untouched for almost forty years
    """

    let ad = """
    this episode is brought to you by Acme Mattress. I have been sleeping on an Acme for six months and \
    it has completely changed my mornings. Right now Acme is offering our listeners 20% off your first \
    order plus free shipping. Go to acmemattress.com/history and use promo code HISTORY at checkout. \
    That's acmemattress.com/history for 20 percent off. Terms and conditions apply.
    """

    func testFindsMidrollAndLeavesContentAlone() {
        var transcript = words(content, from: 0)
        let adStart = transcript.last!.end + 1
        transcript += words("we'll be right back after a quick break", from: adStart)
        let readStart = transcript.last!.end + 0.5
        transcript += words(ad, from: readStart)
        let adEnd = transcript.last!.end
        transcript += words("welcome back. " + content, from: adEnd + 0.5)
        let total = transcript.last!.end

        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        guard let segment = found.first else { return }
        XCTAssertEqual(segment.start, readStart, accuracy: 16)
        XCTAssertEqual(segment.end, adEnd, accuracy: 8)
        XCTAssertGreaterThan(segment.confidence, 0.5)
        XCTAssertLessThan(segment.duration, total / 3)
    }

    func testNoAdsInPlainContent() {
        let transcript = words(content + " " + content, from: 0)
        XCTAssertTrue(AdDetector().detect(in: transcript).isEmpty)
    }

    func testPassingMentionIsNotAnAd() {
        let text = content + " you can read the full paper if you go to the university website " + content
        XCTAssertTrue(AdDetector().detect(in: words(text, from: 0)).isEmpty)
    }

    func testCaptionStyleTranscript() {
        var cues: [TranscriptSegment] = []
        var time = 0.0
        func add(_ text: String) {
            for sentence in text.components(separatedBy: ". ") {
                let length = Double(sentence.split(separator: " ").count) / 2.5
                cues.append(TranscriptSegment(start: time, end: time + length, text: String(sentence)))
                time += length + 0.2
            }
        }
        add(content.replacingOccurrences(of: " and ", with: ". and "))
        let adStart = time
        add(ad)
        let adEnd = time
        add(content)
        add(content.replacingOccurrences(of: " and ", with: ". and "))
        let found = AdDetector().detect(in: cues)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, adStart, accuracy: 16)
        XCTAssertEqual(found.first?.end ?? -1, adEnd, accuracy: 16)
    }

    func testSpokenURLForm() {
        let spoken = """
        support for this podcast comes from Globex. Globex makes payroll easy for small businesses. \
        Sign up today at globex dot com slash pod to get your first month free. That's globex dot com slash pod.
        """
        let transcript = words(content, from: 0) + words(spoken, from: 200) + words(content, from: 240)
        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, 200, accuracy: 5)
    }

    func testChapterDetection() {
        let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 300, title: "Sponsor: Acme"),
                        Chapter(start: 390, title: "Adventures in Peru"), Chapter(start: 900, title: "Ad break"),
                        Chapter(start: 960, title: "Zero-Cost Support, YouTube, Reviews, Sponsors, Newsletter")]
        let found = AdDetector().detect(in: chapters, episodeDuration: 1000)
        XCTAssertEqual(found.map(\.start), [300, 900])
        XCTAssertEqual(found.map(\.end), [390, 960])
        XCTAssertFalse(AdDetector.isAdChapterTitle("Sponsorship models in sport"))
        XCTAssertFalse(AdDetector.isAdChapterTitle("Adolescence, Meaning-Making"))
    }

    func testMerge() {
        let a = AdSegment(start: 10, end: 50, confidence: 0.5, reason: "a")
        let b = AdSegment(start: 40, end: 70, confidence: 0.9, reason: "b")
        let c = AdSegment(start: 200, end: 230, confidence: 0.7, reason: "c")
        let merged = AdDetector.merge([c, a], [b])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].end, 70)
        XCTAssertEqual(merged[0].confidence, 0.9)
    }

    func testReconcileUsesMeasuredEndAndNotesStart() {
        // Transcript only caught the closing call to action; notes know the full read.
        let measured = [AdSegment(start: 160, end: 184, confidence: 0.7, reason: "spoken")]
        let notes = [AdSegment(start: 100, end: 180, confidence: 0.9, reason: "notes"),
                     AdSegment(start: 500, end: 560, confidence: 0.9, reason: "notes")]
        let result = AdDetector.reconcile(measured: measured, approximate: notes)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].start, 104)
        XCTAssertEqual(result[0].end, 184)
        // The ad only the notes list is shifted by the same 4 seconds.
        XCTAssertEqual(result[1].start, 504)
        XCTAssertEqual(result[1].end, 564)
    }

    func testStoryStyleReadIsCoveredFromFirstBrandMention() {
        let read = """
        I have worked with a hundred founders over the years. This is where Zorblat comes in. Zorblat is a tool \
        that answers customer questions for you. \(content) So check it out and learn more at zorblat.ai/show. \
        That's zorblat.ai/show.
        """
        // Read follows the conversation without a break: start at the sponsor's first mention.
        let lead = words(content + ".", from: 0)
        let readStart = lead.last!.end + 0.3
        let continuous = lead + words(read, from: readStart) + words(content, from: readStart + 140)
        var found = AdDetector().detect(in: continuous)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, readStart + 4, accuracy: 2)

        // Read edited in after a beat of silence: the silence is the true start,
        // which also covers the lead-in sentence that never names the sponsor.
        found = AdDetector().detect(in: lead + words(read, from: readStart + 4) + words(content, from: readStart + 140))
        XCTAssertEqual(found.first?.start ?? -1, readStart + 4, accuracy: 0.5)
    }

    func testAnalyzerUsesShowNotesAlone() {
        var evidence = EpisodeEvidence()
        evidence.duration = 2344
        evidence.episodeTitle = "Essentials: How Emotions Impact Learning | Dr. Mary Helen Immordino-Yang"
        evidence.showNotes = """
        Thank you to our sponsors
        (00:00:00) Mary Helen Immordino-Yang
        (00:00:24) Inspiration, Awe & Story
        (00:06:10) Sponsor: LMNT
        (00:07:42) Early Emotional Experiences
        (00:38:20) Acknowledgements
        """
        let analysis = EpisodeAnalyzer().analyze(evidence)
        XCTAssertEqual(analysis.segments.map(\.start), [370])
        XCTAssertEqual(analysis.segments.map(\.end), [462])
        XCTAssertEqual(analysis.contentStart, 24)
    }

    func testShowNotesFormats() {
        let bracketed = "[00:00:00] Start.\n[00:01:59] First topic\n[01:09:20] Parting thoughts."
        XCTAssertEqual(ShowNotes.chapters(from: bracketed).map(\.start), [0, 119, 4160])
        let split = "00:00\nIntro\n01:44\nSecond\n04:48\nThird"
        XCTAssertEqual(ShowNotes.chapters(from: split).map(\.title), ["Intro", "Second", "Third"])
        XCTAssertTrue(ShowNotes.chapters(from: "We met at 10:30 and talked until 9:15.").isEmpty)
        let trailing = "Why labs fall short [2:15];\nDefining health [5:45];\nA practical framework [53:30]; and"
        XCTAssertEqual(ShowNotes.chapters(from: trailing).map(\.start), [135, 345, 3210])
        XCTAssertEqual(ShowNotes.chapters(from: trailing).first?.title, "Why labs fall short")
        // A first entry that is a topic, not an intro, must not be skipped.
        XCTAssertTrue(IntroDetector.isIntroChapter("Intro", episodeTitle: ""))
        XCTAssertTrue(IntroDetector.isIntroChapter("Paul Stamets", episodeTitle: "Mushrooms for the Mind | Paul Stamets"))
        XCTAssertFalse(IntroDetector.isIntroChapter("Why sleep matters", episodeTitle: "Sleep | Dr. Someone"))
    }

    func testRepeatedReadIsFoundWithoutAnyAdLanguage() {
        let jingle = """
        the winter collection was built with the greatest gift giver of all time who counts on durable gear to have \
        his back through rain sleet and snow on the biggest night of the year because when everyone is counting on \
        you to do your job what else would you wear to work grab a gift for every hard working person on your list
        """
        let other = words("completely different episode " + jingle + " goodbye", from: 0)
        var evidence = EpisodeEvidence()
        evidence.transcript = words(content, from: 0) + words(content.uppercased(), from: 700) + words(jingle, from: 1000)
            + words("and that is the end of that story about the river", from: 1100)
        evidence.duration = 5000
        // The same content read twice 700s apart counts as a repeat too, so use distinct halves.
        evidence.transcript = words(content, from: 0) + words(jingle, from: 1000)
            + words("and that is the end of that story about the river", from: 1100)
        XCTAssertTrue(EpisodeAnalyzer().analyze(evidence).segments.isEmpty)

        evidence.reference = Set(RepetitionDetector.fingerprint(of: other))
        let segments = EpisodeAnalyzer().analyze(evidence).segments
        XCTAssertEqual(segments.count, 1, "\(segments)")
        XCTAssertEqual(segments.first?.start ?? -1, 1000, accuracy: 1)
        XCTAssertEqual(segments.first?.kind, .ad)
    }

    // The next tests reproduce, with invented sponsors, the shapes that real
    // episodes threw up while tuning against speech-recognition output.

    func testRecognizerURLSpellings() {
        // Recognisers split the domain and spell the slash: "zorb sleep .com slash pod".
        let read = """
        I'd like to take a quick break and acknowledge our sponsor, Zorb Sleep. Zorb Sleep makes mattress covers. \
        \(content) Go to zorb sleep .com slash pod to get up to $400 off. Again, that's zorb sleep .com slash pod.
        """
        let transcript = words(content + ".", from: 0) + words(read, from: 100) + words("So " + content, from: 300)
        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, 100, accuracy: 1)
        // Ends with the repeated URL, well before the content that follows.
        XCTAssertLessThan(found.first?.end ?? .infinity, 300)
        XCTAssertGreaterThan(found.first?.end ?? 0, 150)
    }

    func testReadWithoutSlashURLOrPromoCode() {
        let read = """
        This episode is brought to you by Quibble, which I have used for more than a decade. \(content) \
        Get your free Quibble shaker in the welcome kit at drinkquibble.com. That's drinkquibble.com.
        """
        let transcript = words(content + ".", from: 0) + words(read, from: 100) + words("Let's talk about Korea. " + content, from: 300)
        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, 100, accuracy: 1)
    }

    func testProducedSpotWithNoSponsorLanguage() {
        let spot = """
        Zorbhart's holiday gift guides were built with the greatest gift giver of all time. Tap the banner to grab \
        a gift for every hard-working person on your list. Or head to Zorbhart.com.
        """
        let transcript = words(content + ". Thank you so much.", from: 0) + words(spot, from: 100)
        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, 100, accuracy: 1)
    }

    func testContentThatMentionsWebsitesAndSponsorsIsLeftAlone() {
        // A guest's site named three times, and an outro thanking sponsors and plugging the newsletter.
        let text = """
        \(content). We curated a website called mushroomreferences.com with a thousand papers. I would refer people \
        to mushroomreferences.com or just google it, you know, mushroomreferences.com. \(content). \
        Please also check out the sponsors mentioned at the beginning of today's episode. That's the best way to \
        support this podcast. \(content). The newsletter is zero cost. You simply go to ourshow.com and enter your email.
        """
        XCTAssertTrue(AdDetector().detect(in: words(text, from: 0)).isEmpty)
    }

    func testColdOpenTeaserDoesNotMarkTheOriginalClipAsAnAd() {
        let clip = """
        I do not want to be alarmist but this is not the last time it will happen and right now two farms are in \
        quarantine because the animals are sick and the system has the wisdom to protect the host and you are a \
        natural product and natural products being used by each other is the lesson of evolution
        """
        var evidence = EpisodeEvidence()
        evidence.duration = 6000
        evidence.transcript = words(clip, from: 0) + words("Welcome to the show. " + content, from: 50)
            + words(clip, from: 3900) + words(content.split(separator: " ").reversed().joined(separator: " "), from: 3960)
        let segments = EpisodeAnalyzer().analyze(evidence).segments
        XCTAssertEqual(segments.count, 1, "\(segments)")
        XCTAssertEqual(segments.first?.kind, .boilerplate)
        XCTAssertEqual(segments.first?.start ?? -1, 0, accuracy: 1)
    }

    func testCommonWordInSponsorDomainDoesNotDragTheStartBack() {
        // "from our place .com": the word "place" earlier in the conversation is not the sponsor.
        let question = "I am a researcher in Japan and this place has changed how my students think about work."
        let read = """
        I cook most nights with a pan from today's sponsor, Our Place. \(content) Visit from our place .com slash pod \
        and use code POD for 10% off. That's from our place .com slash pod.
        """
        let transcript = words(question + " " + content + ".", from: 0) + words(read, from: 100)
        let found = AdDetector().detect(in: transcript)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.start ?? -1, 100, accuracy: 1)
    }

    func testHouseURLIsNotASponsor() {
        let plug = """
        I wanted to tell you about it. If you go to tim.blog/oryx you can still sign up for the wait list. \
        There are not many spots and I was skeptical at first but the team has been great to work with and I think \
        a lot of you would get real value from trying it for a few weeks. \
        Again, go to tim.blog/oryx and check it out. \(content)
        """
        let transcript = words(content + ".", from: 0) + words(plug, from: 100)
        var detector = AdDetector()
        detector.options.showName = "The Tim Ferriss Show Tim Ferriss"
        XCTAssertTrue(detector.detect(in: transcript).isEmpty)
        // The same wording for somebody else's site is a sponsor read.
        let sponsor = plug.replacingOccurrences(of: "tim.blog", with: "zorblat.com")
        XCTAssertEqual(detector.detect(in: words(content + ".", from: 0) + words(sponsor, from: 100)).count, 1)
    }

    func testAnnouncedBreakCoversSpotsWithNoAdLanguage() {
        let spot = "Looking for a new mattress. Zorb has twenty models to choose from. Go to zorbsleep.com/pod for 20% off."
        let plain = "If car shopping feels like a whole thing, buying your car online makes it way easier. Really. Shop tons of cars and compare prices from wherever you are."
        let other = content.split(separator: " ").reversed().joined(separator: " ")
        var evidence = EpisodeEvidence()
        evidence.transcript = words(content + ". We'll be right back.", from: 0) + words(spot, from: 82) + words(plain, from: 100)
            + words("All right, back to the show. " + other, from: 115)
        let segments = EpisodeAnalyzer().analyze(evidence).segments
        XCTAssertEqual(segments.count, 1, "\(segments)")
        XCTAssertEqual(segments.first?.start ?? -1, 82, accuracy: 1)
        XCTAssertEqual(segments.first?.end ?? -1, 115, accuracy: 3)

        // "Stay with me" and a much later "welcome back" with nothing sponsor-like between: not a break.
        evidence.transcript = words("Stay with me. " + content + ". Welcome back to the story. " + other, from: 0)
        XCTAssertTrue(EpisodeAnalyzer().analyze(evidence).segments.isEmpty)
    }

    func testSponsoredSegmentIsSkippedWhole() {
        let other = content.split(separator: " ").reversed().joined(separator: " ")
        let segment = """
        This segment is sponsored by Zorbmart. While you are busy getting ready for the holidays their buyers have \
        your back. \(other). I want to give another big thank you to Zorbmart for sponsoring this segment. \
        Shop now at zorbmart.com or find a store near you.
        """
        var evidence = EpisodeEvidence()
        evidence.transcript = words(content + ". I'll see you in the next episode.", from: 0) + words(segment, from: 100)
        let segments = EpisodeAnalyzer().analyze(evidence).segments
        XCTAssertEqual(segments.count, 1, "\(segments)")
        XCTAssertEqual(segments.first?.start ?? -1, 100, accuracy: 1)
        XCTAssertGreaterThan(segments.first?.duration ?? 0, 60)

        // An opening with no closing thank-you can't be bounded, so it is left alone.
        evidence.transcript = words("This segment is sponsored by Zorbmart. " + content + " " + other, from: 0)
        XCTAssertTrue(EpisodeAnalyzer().analyze(evidence).segments.isEmpty)
    }

    func testIntroHandoff() {
        let intro = "Welcome to the show. Today my guest is a historian. Without further ado, please enjoy this conversation."
        let transcript = words(intro, from: 0) + words(content, from: 10)
        let start = IntroDetector().contentStart(in: transcript, ads: [])
        XCTAssertEqual(start ?? -1, 7, accuracy: 1.5)
        XCTAssertNil(IntroDetector().contentStart(in: words(content, from: 0), ads: []))
    }

    func testSkipPlanner() {
        let segments = [AdSegment(start: 100, end: 160, confidence: 0.9, reason: ""),
                        AdSegment(start: 160.5, end: 200, confidence: 0.9, reason: ""),
                        AdSegment(start: 500, end: 530, confidence: 0.2, reason: "")]
        XCTAssertNil(AdSkipPlanner.skipTarget(at: 99, segments: segments))
        XCTAssertEqual(AdSkipPlanner.skipTarget(at: 100.2, segments: segments)?.target, 200)
        XCTAssertEqual(AdSkipPlanner.skipTarget(at: 199.5, segments: segments)?.target, nil)
        XCTAssertNil(AdSkipPlanner.skipTarget(at: 510, segments: segments, minimumConfidence: 0.5))
        XCTAssertNotNil(AdSkipPlanner.skipTarget(at: 510, segments: segments))
    }
}

final class DiscoveryTests: XCTestCase {
    func show(_ id: Int, feed: String) -> PodcastSearchResult {
        PodcastSearchResult(id: id, title: "Show \(id)", author: "", feedURL: URL(string: feed)!, artworkURL: nil,
                            genre: nil, episodeCount: nil)
    }

    func testSearchDecoding() throws {
        let json = """
        {"resultCount":2,"results":[
          {"collectionId":1,"collectionName":"A","artistName":"X","feedUrl":"https://a.example/feed",
           "artworkUrl100":"https://a.example/100.jpg","artworkUrl600":"https://a.example/600.jpg",
           "primaryGenreName":"Daily News","trackCount":10,"genreIds":["1526","26","1489"]},
          {"collectionId":2,"collectionName":"No feed"}]}
        """
        let results = try PodcastSearch.decodeResults(Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].artworkURL?.absoluteString, "https://a.example/600.jpg")
        XCTAssertEqual(PodcastTheme.theme(genreIDs: results[0].genreIDs)?.name, "News")
        XCTAssertEqual(PodcastTheme.theme(genreIDs: [], categoryNames: ["Software", "technology"])?.id, 1318)
    }

    func testChartDecoding() throws {
        let json = #"{"feed":{"entry":[{"id":{"label":"x","attributes":{"im:id":"42"}}},{"id":{"label":"y","attributes":{"im:id":"7"}}}]}}"#
        XCTAssertEqual(try PodcastDiscovery.decodeChartIDs(Data(json.utf8)), [42, 7])
        let ordered = PodcastDiscovery.ordered([show(7, feed: "https://b"), show(42, feed: "https://a")], by: [42, 7])
        XCTAssertEqual(ordered.map(\.id), [42, 7])
    }

    func testRecommendations() {
        XCTAssertEqual(PodcastDiscovery.rankedThemes(subscribedThemeIDs: [1318, 1489, 1489, 1303, 999], limit: 2).map(\.id),
                       [1489, 1318])
        let tech = [show(1, feed: "https://one.example/feed/"), show(2, feed: "https://two.example/feed")]
        let news = [show(3, feed: "https://three.example/feed"), show(2, feed: "https://two.example/feed")]
        let picks = PodcastDiscovery.recommendations(charts: [tech, news],
                                                     subscribedFeedURLs: [URL(string: "http://ONE.example/feed")!])
        XCTAssertEqual(picks.map(\.id), [3, 2])
    }
}

final class SyncMergeTests: XCTestCase {
    func testNewerShowRecordWins() {
        let local = [SyncedShow(feedURL: "https://a.example/feed", title: "A", speed: 1.0, introSkip: 0, updatedAt: 200),
                     SyncedShow(feedURL: "https://b.example/feed", title: "B", speed: nil, introSkip: 0, updatedAt: 100)]
        let remote = [SyncedShow(feedURL: "http://A.example/feed/", title: "A", speed: 1.5, introSkip: 30, updatedAt: 150),
                      SyncedShow(feedURL: "https://b.example/feed", title: "B", speed: nil, introSkip: 0, updatedAt: 300, removed: true),
                      SyncedShow(feedURL: "https://c.example/feed", title: "C", speed: 1.3, introSkip: 0, updatedAt: 50)]
        let merged = SyncMerge.mergeShows(local: local, remote: remote)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first { $0.title == "A" }?.speed, 1.0)       // local change is newer
        XCTAssertEqual(merged.first { $0.title == "B" }?.removed, true)    // removed on the other device
        XCTAssertEqual(merged.first { $0.title == "C" }?.speed, 1.3)       // added on the other device
        // Applying the same merge from the other side gives the same answer.
        XCTAssertEqual(SyncMerge.mergeShows(local: remote, remote: local), merged)
    }

    func testProgressMergeAndCap() {
        let local = ["ep1": SyncedProgress(position: 600, played: false, updatedAt: 20),
                     "ep2": SyncedProgress(position: 0, played: true, updatedAt: 5)]
        let remote = ["ep1": SyncedProgress(position: 300, played: false, updatedAt: 10),
                      "ep2": SyncedProgress(position: 90, played: false, updatedAt: 8),
                      "ep3": SyncedProgress(position: 42, played: false, updatedAt: 1)]
        let merged = SyncMerge.mergeProgress(local: local, remote: remote)
        XCTAssertEqual(merged["ep1"]?.position, 600)
        XCTAssertEqual(merged["ep2"]?.played, false)
        XCTAssertEqual(merged["ep3"]?.position, 42)
        XCTAssertEqual(Set(SyncMerge.mergeProgress(local: local, remote: remote, limit: 2).keys), ["ep1", "ep2"])
        XCTAssertEqual(SyncMerge.progressKey(forFeed: URL(string: "https://a.example/feed")!),
                       SyncMerge.progressKey(forFeed: URL(string: "http://A.example/feed/")!))
    }
}

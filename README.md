# SkipCast

A podcast player for iPhone that skips the commercials.

Search or browse the podcast directory, subscribe, have the newest episodes
downloaded automatically, and play them at 1×–2× with 30-second skips. Turn on
**Skip ads** and sponsor reads are jumped over as you listen; turn on
**Skip intro** to start each episode where the conversation actually begins.

## Running it on your iPhone

You need a Mac with Xcode 16 or later.

1. Open `SkipCast.xcodeproj`.
2. Select the **SkipCast** target → *Signing & Capabilities* → pick your team
   (a free Apple ID works) and change the bundle identifier to something unique.
3. Plug in your iPhone, choose it as the run destination, and press Run.

The first time an episode is scanned, iOS asks for Speech Recognition
permission. Scanning happens on the device; audio is never uploaded.

## How ads are found

Feeds don't mark where ads are, so SkipCast combines three sources of evidence
(`Core/Sources/PodcastCore`):

| Source | Needs a download? | What it gives |
| --- | --- | --- |
| **Show notes index** – timestamped notes such as `(00:06:10) Sponsor: LMNT` | No | Instant ad and intro positions for shows that publish them |
| **What is said** – the episode is transcribed on the phone and searched for the shape of a sponsor read: an attribution, then a vanity URL / promo code / offer | Yes | Exact start and end of each read, to the sentence |
| **Repetition** – passages spoken word-for-word in another episode, or twice in this one | Yes | Inserted ads with no "ad language", recurring intros/outros, exact edges of reads heard before |

A single cue is never enough to skip: a block needs several independent pieces
of evidence, so a guest mentioning their website or a host thanking "our
sponsors" in the outro is left alone. Every skip shows an **Undo** button, and
detected breaks are drawn on the progress bar.

When only show notes are available and the stream turns out to be longer than
the published duration (extra ads were inserted, so timestamps have shifted),
skipping is switched off for that play rather than risk cutting content.

### Checking it against real episodes

`adscan` runs the analyser over a word-timestamp transcript and prints each
detection with the text around its edges:

```bash
swift run --package-path Core adscan transcript.json --feed feed.xml --item 0 --ref other-episode.json
```

Transcript format: `{"words":[{"start":0.0,"end":0.4,"text":"hello"}, …]}`.

## Layout

- `Core/` – Swift package with everything that doesn't touch the UI: feed
  parsing, directory search, show-notes parsing, ad/intro detection. Runs and
  is tested on Linux and macOS (`swift test --package-path Core`).
- `SkipCast/` – the SwiftUI app (iOS 17+): SwiftData library, background
  downloads, AVPlayer engine, on-device transcription.

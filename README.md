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

## Downloads, speed, sync and CarPlay

- **First sync.** A newly added show downloads its 3 newest episodes, over
  Wi-Fi only. After that, new episodes download as they are published (over
  mobile data too, unless you turn that off), keeping up to the number set in
  Settings.
- **Per-show speed.** Changing speed in the player is remembered for that
  show. Shows without their own speed use the default from Settings.
- **iCloud sync.** Subscriptions, per-show settings and your position in each
  episode sync between devices. This needs the iCloud capability, which Apple
  only allows on a paid Apple Developer account: in Xcode, select the target →
  *Signing & Capabilities* → **+ Capability** → **iCloud** → tick **Key-value
  storage**. Without it the app works normally and simply doesn't sync.
- **CarPlay.** The app has CarPlay screens (Up Next, Shows, Now Playing with a
  speed button). They appear in the CarPlay Simulator out of the box. For a
  real car, Apple must grant your developer account the CarPlay audio
  entitlement (requested at developer.apple.com/contact/carplay); once granted,
  set `CODE_SIGN_ENTITLEMENTS` to `Config/CarPlay.entitlements` for device
  builds. Without it, audio still plays in the car and the car's Now Playing
  controls work; the app just has no icon on the CarPlay screen.

## How ads are found

Feeds don't mark where ads are, so SkipCast combines several sources of
evidence (`Core/Sources/PodcastCore`):

| Source | Needs a download? | What it gives |
| --- | --- | --- |
| **Show notes index** – timestamped notes such as `(00:06:10) Sponsor: LMNT` | No | Instant ad and intro positions for shows that publish them |
| **What is said** – the episode is transcribed on the phone and searched for the shape of a sponsor read: an attribution, then a vanity URL / promo code / offer | Yes | Start and end of each read, to the sentence |
| **Announced breaks** – "we'll be right back … and now back to the show" | Yes | The whole break, including spots with no ad language |
| **Edit pauses** – inserted ads leave a beat of silence at each join; conversation almost never pauses that long | Yes | Exact edges, story-style lead-ins, neighbouring spots |
| **Repetition** – passages spoken word-for-word in another episode, or twice in this one | Yes | Inserted ads, recurring intros/outros |

A single cue is never enough to skip: a block needs several independent pieces
of evidence, so a guest mentioning their website, a host thanking "our
sponsors" in the outro, or a plug for the show's own newsletter is left alone.
Every skip shows an **Undo** button, and detected breaks are drawn on the
progress bar.

When only show notes are available and the stream turns out to be longer than
the published duration (extra ads were inserted, so timestamps have shifted),
skipping is switched off for that play rather than risk cutting content.

Intros are found the same way: an `Intro` entry in the show notes, the host's
hand-off ("without further ado…", "and now for my conversation with…"), a
cold-open teaser that replays a later clip, and opening ads. Each show also has
a manual "skip first N seconds" setting.

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

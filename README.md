# OneShot

An iOS app that finds duplicate photos and videos, picks the best copy of each, and
deletes the rest. Everything runs on the device — no server, no network, no bundled
model weights. It works in aeroplane mode. Matching is done by
[Qdrant Edge](https://qdrant.tech/documentation/edge/), a vector search engine that
runs inside the app.

- **Platform:** iOS 26+, iPhone and iPad
- **Language:** Swift 6 (strict concurrency), SwiftUI
- **Bundle id:** `com.rahil.OneShot`

---

## How detection works

Five phases, in `Engine/DuplicateScanner.swift`.

### 1. Index

`PhotoLibraryService.fetchRecords` flattens the library into `AssetRecord` values.
`PHAsset` is a non-`Sendable` PhotoKit class, so it is never carried across a
concurrency boundary — the scanner reads it once and re-fetches by identifier only
where PhotoKit is genuinely required (loading pixels, deleting).

File sizes here are *estimates* from pixel dimensions. Reading the true size means
loading `PHAssetResource` for every asset, which costs seconds on a large library.
`enrich(_:)` replaces them with real values later, for the few assets that actually
land in a group.

### 2. Fingerprint

Each asset is decoded **once**, to a 128×128 square, and five signals come out of
that one buffer:

| Signal | What it is | What it survives |
| --- | --- | --- |
| **dHash** | 64-bit difference hash of luminance on a 9×8 grid | rescaling, recompression, exposure shifts |
| **Chromaticity histogram** | 8×8 bins over r/(r+g+b), g/(r+g+b) | brightness and exposure changes |
| **Shape signature** | 480 luminance gradients on a 16×16 grid, unit length | all of the above, colour filters, and — searched rotated — quarter-turns |
| **Sharpness** | variance of the Laplacian | — (used for ranking, not matching) |
| **Exposure** | clipping + tonal range | — (used for ranking, not matching) |

The histogram bins **chromaticity, not RGB**. That is not incidental: measured
against a brightened copy of the same photo, an RGB histogram scored **0.50** — well
below any usable threshold — while chromaticity scores **~0.99**, because scaling all
three channels together cancels out of the ratio. The cost is that luminance is
discarded, so a black frame and a white frame both land in the achromatic centre;
`meanLuma` is compared separately to keep them apart.

Video takes the same path, with `AVAssetImageGenerator` sampling five keyframes at
fixed *fractions* of the duration, so a re-exported or trimmed copy still lines up
frame-for-frame.

Fingerprints are cached in SQLite keyed by asset id and validated against the
modification date, so only new or edited assets are re-analysed on later scans.

#### The shape signature, and why not Vision

The shape signature is the vector Qdrant Edge stores and searches. It replaced
Apple's `VNGenerateImageFeaturePrintRequest`, and it is computed by the app, not by a
model: horizontal and vertical luminance differences on a 16×16 grid, normalised.

It is a real-valued, finer relative of dHash. dHash keeps one *bit* per cell — "is the
right neighbour brighter?" — so in flat regions like sky, where neighbours are nearly
equal, its bits flip on compression noise. That is most of why true duplicates sit at
Hamming 8–16. In the signature a flat region contributes almost nothing to the
cosine, so noise barely moves it.

Measured on the synthetic corpus (cosine similarity):

| | Score |
| --- | --- |
| True duplicates — resized, JPEG q25, brightened, blurred burst frame, colour-filtered | **≥ 0.995** |
| Closest of ~1,500 unrelated pairs | 0.887 |
| 99th percentile of unrelated pairs | 0.78 |
| A 90° rotated copy, against the rotated signature | 1.000 |

Two alternatives were measured and rejected: a 16×16 *luminance* grid and low DCT
coefficients both scored unrelated photos above **0.98**, because both are dominated
by the shared "bright sky over dark ground" layout — the same trap described for dHash
below. Gradients cancel the layout out.

The signature is deliberately not mean-centred. That keeps a quarter-turn of the image
an exact signed permutation of the vector, so a photo's rotations are searched for
without decoding it again. It is stored in half precision, which moved no measured
similarity by more than 0.001.

Vision's feature print measured *semantic* similarity — two photographs of two
different beaches scored close together, which is a true statement and the wrong
question for a duplicate finder. It also could not be exercised offline, so its
thresholds were the least-validated numbers in the app. Every shape threshold below
is measured.

### 3. Compare

**This is exhaustive, and that is a deliberate reversal.**

It was originally banded locality-sensitive hashing: split each 64-bit hash into
eight 8-bit bands, only compare assets colliding in a band. Measuring it against a
library with known duplicates showed why that was wrong. Real duplicates land at
Hamming distances of **8 to 16**, and at those distances banding surfaces only
**57–70%** of pairs. A five-member group survived because its ten pairs gave it ten
chances to collide; a plain two-photo duplicate had exactly one chance and was
silently missed.

So every pair is compared. 30,000 photos is 450 million pairs, but each is an XOR, a
popcount and a compare over flat cache-resident arrays, parallelised across cores —
about a second, against a decode phase measured in minutes. Complete recall is worth
far more than that second. The 64-bin histogram is only touched for pairs that
survive the hash test.

Rejections run cheapest-first: mean luminance, then aspect ratio, then hash, then
histogram.

### 4. Verify

`Engine/PairVerifier.swift`. A pair is accepted directly by either of two routes:

- **Structure-led** — hash within `hashAccept` *and* histogram above `histogramAccept`.
- **Colour-led** — histogram at or above `strongHistogram` (near-perfect) *and* hash
  within `colourLedHashLimit`.

The colour-led route exists because heavy JPEG recompression pushes a copy of the
same photo to Hamming 16 while its colour distribution holds at 0.97+, whereas
unrelated photographs sat at 0.40–0.52. Colour proved the more decisive signal, so it
gets a route of its own rather than only ever acting as a veto.

It carries its own tight hash bound. Without one, `Similar scenes` merged five
unrelated photographs into a single group of eleven — its wide `hashReject` of 30 let
anything with a similar palette through on colour alone.

Pairs in the grey zone between the two routes go to **Qdrant Edge**
(`Engine/VectorIndex.swift`), which scores each one on the shape signature with an
exact search restricted to the pair's own points (a `HasId` filter). One lookup per
photo covers all of that photo's grey-zone partners.

The bar is graded by colour. A pair whose histogram is at `histogramAccept` needs
only `shapeAccept`; one down at `histogramFloor` needs **0.995**, the level every
measured true duplicate reached; in between the bar rises linearly
(`Tuning.shapeRequired`). The less the colours agree, the more exactly the structure
must match. A flat bar treated the frames of a slow cross-fade — identical layout,
drifting colours — like colour-filtered copies, and grew the chaining test's largest
group from 21 to 31; graded, it is 27.

A colour-filtered copy is the case this exists for: measured at hash 3 and histogram
0.86, it fails both direct routes at `.strict`, and its shape similarity of 0.9996
confirms it.

#### Neighbour search: what the hash cannot see

Qdrant Edge then searches the whole library for each photo's nearest shapes, in all
four orientations, and confirms new pairs that also agree on colour
(`histogramAccept`), brightness and orientation-normalised aspect.

This finds **rotated copies**, which the hash scan could never find: a rotated copy
measured at Hamming 23–39, past every reject threshold. Screenshot pairs are excluded,
since two screens of one app share most of their edges.

The search is **incremental**. Each photo's neighbours are stored on its own Qdrant
point, with each neighbour's modification stamp at the time. Only photos that are new,
edited or never searched pay for a search, and an entry whose neighbour has since been
edited is ignored. At 20,000 photos the full search costs tens of seconds, which on
every rescan would have made it the slowest part of a rescan; incrementally a rescan
spends 0.4 s on it.

Blank frames get a special guard: an all-black photo has an all-zero hash and matches
every other blank frame. Without it, thirty accidental lens-cap shots become one
enormous bogus group.

Screenshots are a special case. Two screenshots of the same app share their status
bar, navigation chrome and palette, so the colour histogram describes the app rather
than the content — unrelated screens routinely score above 0.98. Screenshot-to-
screenshot pairs therefore skip the colour-led route entirely and must agree
structurally (hash ≤ 6).

#### Why `Similar scenes` is a *temporal* mode

The three sensitivities were originally just three sets of visual thresholds, with
`.similar` being the loosest. That does not work, and it is worth being precise about
why: a Hamming distance of 18 out of 64 plus a chromaticity match of 0.78 describes
an enormous share of ordinary photographs. A 64-bit luminance-gradient hash keys on
gross composition, so *any* "bright sky above, darker ground below" photo resembles
*any* other. Loosening thresholds library-wide grouped forty unrelated pictures.

The Vision escalation, which Qdrant Edge has since replaced, made it worse rather
than better. Feature prints measure *semantic* similarity — two different photographs
of two different beaches score close together, which is a true statement and
completely the wrong question. At an acceptance distance of 0.85 it was confirming
pairs that were merely the same kind of subject.

What the mode is actually for — burst frames, and re-taking a shot of the same
subject — has a property the thresholds were ignoring: **it happens within seconds or
minutes.** So `.similar` is now `.strict` *plus* a temporal route:

| Route | Thresholds | When |
| --- | --- | --- |
| Anytime | `.strict` values | any two photos, whenever taken |
| Same moment | relaxed values | captured within 3 minutes of each other |
| Qdrant Edge | shape ≥ `shapeRequired` | only for pairs one of the above already bracketed |

`.similar` therefore remains a strict superset of `.strict` — it can only ever find
more — while its extra reach is confined to frames that plausibly belong to one
moment. Assets with no capture date count as *not* the same moment, since without a
timestamp there is no evidence for the temporal route.

Gating escalation on the same test also stops `.similar` sending Qdrant thousands of
pairs it was never going to accept. The neighbour search uses the anytime thresholds
at every sensitivity: its pairs arrive with no hash agreement, so the same-moment
relaxation does not extend to them.

### 5. Cluster, refine, and score

Union-find merges pairs into **connected components**, which is not quite the
question being asked. It answers "is there a *path* of similarity between these two
photos". If A resembles B, B resembles C and C resembles D, all four land in one
group — even when A and D have nothing in common. On a real library those chains run
for hundreds of photos and the first group swallows most of the library. A 19-image
test corpus has chains too short to reveal this; a 40-frame morph sequence collapses
into a single 35-member blob.

So each component is refined by **star clustering**: repeatedly take the
best-connected photo still unassigned, and form a group from it and the photos that
matched *it* directly. Every member of the resulting group is a confirmed match
against the same anchor, so nothing arrives by transitive association and the group
means what the user thinks it means — "these are all copies of this one". Groups are
capped at 60 members; beyond that the least similar are left for the next anchor
rather than piled onto one unreviewable card.

Each group member is then scored. Every measured dimension is normalised **within
that group**: absolute sharpness is meaningless across scenes, but "sharpest of these
four near-identical frames" is exactly the question. User intent (favourited, edited)
is a flat bonus large enough to override the measurements — a starred photo should
never lose to a marginally sharper copy.

| Weight | Dimension |
| --- | --- |
| 3.0 | Sharpness |
| 2.5 | Resolution (log scale) |
| 2.0 | Faces — count and eyes-open |
| 1.2 | Exposure |
| 0.8 | File size |
| +5.0 | Favourited |
| +1.2 | Your edit |
| +0.8 | Live Photo / HDR |
| −1.5 | A screenshot in a group that also has real photos |

Face detection is the most expensive per-asset operation in the app — a decode plus a
Vision request per photo — so it is gated three ways:

- Only groups whose members differ meaningfully in sharpness (the burst case, where
  "who blinked" decides it). Exact copies have identical faces, so analysing them
  changes nothing.
- Only the **top three contenders** in a group, not every member. Photos already
  behind on sharpness and resolution cannot be rescued by an eye-open bonus, so
  analysing them is wasted work. Members that were not analysed receive a neutral
  half-share of the face weight rather than zero, so they are not punished for work
  that was deliberately skipped.
- A hard ceiling of 400 analyses per scan.

Reading true file sizes (`PHAssetResource`) is a per-asset hit on the Photos database
and is chunked across cores for the same reason.

---

## Verification

### The test suite (`OneShotTests`)

The ground-truth tests now live in the project, in a unit-test target hosted by the
app, and run against a **real Qdrant Edge shard on the iOS simulator**. The corpus is
a CoreGraphics port of the Android engine's generator, so both platforms test the same
scenes. The tests call the same `CandidateIndex` → `PairVerifier` → `UnionFind` →
`ClusterRefiner` code the scanner does.

```bash
xcodebuild test -project OneShot.xcodeproj -scheme OneShot -destination 'platform=iOS Simulator,name=iPhone 17'
```

| Test | Result |
| --- | --- |
| Seeded library, all three sensitivities | **4 groups, [5, 3, 2, 2], 8 duplicates, 0 mixed** |
| `Similar scenes` hostile corpus | [6, 2] at Near-identical and Similar, [4, 2, 2] at Exact; **0 mixed** at all three |
| Chaining (40-frame cross-fade) | union-find 33 → refined 27; endpoints apart; 0 transitive members. Hash routes alone: 21 |
| Blank frames | black pair grouped, white frame excluded |
| Brightened copy | histogram 0.96 |
| **Rotated copies** (new) | original + 3 rotations, and a rotated pair: **[4, 2] at all three sensitivities**; the hash routes link none of them to the original |
| **Colour-filtered copy** (new) | escalates past both direct routes; Qdrant confirms it and only it |
| **Stored neighbours** (new) | reused by a rescan; an edit into a different picture invalidates the pair from both ends |
| Device corpus (below) | **[6, 3, 3, 2], 10 duplicates** |
| Qdrant Edge wrapper | persistence across reopen, resync writes only changes, `HasId` scores equal cosine to 0.003, unreadable shard rebuilt, cancellation stops the search |

**End to end, on the simulator's real photo library.** `LibraryScanTests` (opt-in)
runs `DuplicateScanner.scan` exactly as the Scan button does — PhotoKit, fingerprinting,
SQLite, Qdrant Edge, verification, clustering, keeper scoring. The library was seeded
with the 21-photo device corpus (the seeded library plus a rotated sunset and a
colour-filtered valley) alongside the simulator's own six sample photos:

| | Result |
| --- | --- |
| First scan | 27 assets, 1.7 s → **[6, 3, 3, 2], 10 duplicates**, no sample photo grouped |
| Rescan | 0.22 s, identical groups |
| Cache on disk | 316 KB, SQLite and the Qdrant shard together |

```bash
TEST_RUNNER_ONESHOT_CORPUS_OUT=/tmp/corpus xcodebuild test ... -only-testing:OneShotTests/CorpusExport
xcrun simctl addmedia booted /tmp/corpus/*.png
xcrun simctl privacy booted grant photos com.rahil.OneShot
TEST_RUNNER_ONESHOT_LIBRARY_SCAN=1 xcodebuild test ... -only-testing:OneShotTests/LibraryScanTests
```

**At library scale** — 20,000 shapes, on the simulator (the Mac's CPU, not a
phone's), with random vectors as the worst case for a graph index:

| | Time |
| --- | --- |
| Write and build the HNSW index (first scan only) | 5–32 s, varying run to run |
| Neighbour search, first scan | 27–32 s |
| Neighbour search, rescan | **0.4 s** |
| A photo finding its own shape (recall) | 1999 / 2000 at `ef` 64 |

A phone will be slower; the first-scan costs are one-off and sit alongside a
fingerprinting pass that already takes minutes at that size.

### The original harness

`Engine/` is deliberately free of UIKit and PhotoKit dependencies below
`PhotoLibraryService`, so the detection pipeline can be compiled and exercised
standalone on synthetic images with known relationships. That harness is what caught
every bug listed below; the numbers in the rest of this section are from it, before
Qdrant Edge.

Measured against a seeded library of 19 images with known ground truth — one photo
saved five ways, a three-frame burst, a resized pair, six unrelated photographs, two
identical black frames and a white frame:

**Result: 4 groups, 8 duplicates — an exact match to ground truth, with no false
positives.** The six unrelated photographs and the lone white frame were correctly
left ungrouped.

Representative distances from that run:

| Pair | Hamming | Histogram |
| --- | --- | --- |
| original ↔ resized 50% | 13 | 0.999 |
| original ↔ resized 25% | 13 | 0.999 |
| original ↔ JPEG q25 | 11 | 0.987 |
| original ↔ brightened | 10 | 0.980 |
| valley original ↔ copy | 8 | 0.990 |
| **unrelated photographs** | **21–29** | **0.40–0.52** |

### Chaining test

A 40-frame sequence morphing from one scene to an unrelated one: each frame is
near-identical to its neighbour, the endpoints have nothing in common. This is the
shape of a real photo library, and the shape a small test corpus cannot produce.

| | Result |
| --- | --- |
| Union-find components | **35**, 5 |
| After star clustering | 12, 6, 5, 5, 3, 3, 2, 2 |
| First and last frame grouped together | no |
| Members not directly matched to their anchor | **0** |

The 35-member blob is the reported failure reproduced in miniature. Refinement breaks
it into reviewable groups while the seeded library still resolves to exactly its
4 correct groups.

### `Similar scenes` test

A corpus built to be hostile in the way a real library is: 43 photographs that all
share the same gross composition, so the hash has every chance to confuse them.
6 burst frames 2 s apart, 2 reshoots of one subject 55 s apart, 25 unrelated photos
one per day, and 10 unrelated photos only 30 s apart — the last group being the hard
case, since closeness in time must not by itself imply duplication.

| | Confirmed | Groups | Mixed groups |
| --- | --- | --- | --- |
| **Control** (previous thresholds, no temporal gate) | 18 | 6, 3, 2 | **2** |
| Exact | 10 | 6, 2 | 0 |
| Near-identical | 16 | 6, 2 | 0 |
| **Similar scenes** | 16 | 6, 2 | **0** |

The control establishes that this corpus reproduces the reported failure. All three
current modes find exactly the burst and the reshoot and nothing else; the 35
unrelated photographs are correctly left alone, including the ten taken half a minute
apart.

Re-run in the app against the seeded library — where every asset shares an import
timestamp, so the temporal gate is wide open, the worst case for this design —
`.similar` returns the same 4 groups and 8 duplicates as `.strict`, with no
contamination.

### Bugs this caught

1. **RGB histogram broke on exposure changes** — a brightened copy scored 0.50 and
   was rejected before it was even a candidate. Fixed by binning chromaticity.
2. **LSH banding silently missed two-photo duplicates** — 57–70% recall in the range
   where real duplicates live. Replaced with an exhaustive scan.
3. **`.aspectFill` was centre-cropping every thumbnail.** Requesting a *square*
   target size with `.aspectFill` makes PhotoKit return a centre crop, discarding the
   left and right quarters of every 4:3 frame — so the hash described only the middle
   of the picture, and none of the calibration applied to what the app actually did.
   Fixed by requesting `.aspectFit` and squashing to square in `rasterize`. This was
   the bug that hid the resized pair.
4. **Confidence read as "Possible" for certain duplicates** — the hash term was too
   harsh and averaging across a group's pairs dragged large groups down.
5. **Every group was labelled "Burst"** — timestamps alone are not enough, since an
   imported batch shares one import time. Now requires identical pixel dimensions and
   three or more members.
6. **No way to rescan** from the results screen without quitting the app.
7. **Cache size under-reported** — counted only the main SQLite file, ignoring the
   WAL that held most of the data.
8. **Transitive chaining produced enormous groups** — reported from real-device use:
   a library of ~1000 photos returned ~900 of them as a single "duplicate" group.
   Union-find's connected components chain through intermediate photos. Fixed with
   star clustering, plus a tightened `colourLedHashLimit` (18 → 14 at `.strict`, too
   close to the 21–29 band where unrelated photographs sit) and a structure-only rule
   for screenshot pairs.
9. **The scoring phase was slow** — face detection ran on every member of every
   group, and true file sizes were read serially. Now three contenders per group and
   chunked across cores.
10. **`Similar scenes` grouped forty unrelated photos** — reported from real-device
    use, after the chaining fix had already landed. Loosening visual thresholds
    library-wide cannot express "the same moment", and the Vision escalation at 0.85
    was confirming pairs that were merely the same kind of subject. Redesigned as
    `.strict` plus a time-gated route.
11. **The group screen went stale after deleting from it.** `removeDeleted` rebuilds
    every `DuplicateGroup`, but the detail screen holds the value it was pushed with,
    so it kept showing photos that no longer existed and offered to delete them a
    second time. It now closes itself on a successful delete.
12. **An empty badge capsule floated on every ordinary photo** — `AssetBadges` drew
    its background unconditionally, even with nothing to put in it.

## Selecting what to delete

A tick means the photo is going; unticked means it stays. Duplicates arrive ticked
and the suggested keeper arrives unticked, so the default is one tap away from being
correct and the whole screen reduces to one idea.

Viewing and marking are separate gestures. Tapping a photo only ever *shows* it;
tapping its checkbox marks it. An earlier version made a second tap on the focused
photo toggle it, which meant browsing and deleting were the same gesture.

The recommendation is advice, not a lock — the starred photo can be ticked like any
other. If every copy in a group ends up ticked the screen says so plainly rather than
preventing it.

### Not yet covered

**Crops** remain weak. The shape signature is a fixed grid, so a crop shifts every
cell: a 3% centre crop scores 0.97–0.99, a 5% one 0.92–0.97, a 5% corner crop as low
as 0.68. Small centre crops are found; anything larger is not, by design. Rotations,
the other half of this gap, are now covered.

**Strong colour filters** are still missed. A warm preset measured at histogram 0.58,
below every route's colour floor, although its shape similarity is 0.999. Admitting
it would mean trusting shape alone, which is what lets cross-fades chain.

**Every shape threshold is measured on synthetic photographs only.** The bands —
duplicates ≥ 0.995, unrelated ≤ 0.887 — hold on the corpus; a real library will have
pairs that sit between them, and `shapeAccept` / `neighbourAccept` are the dials for
that.

**Qdrant Edge is beta, and its Swift package is not released.** The build uses the
Swift SDK from an open pull request (qdrant/qdrant#9979), pinned to one commit. The
generated API may change when it merges.

`Tuning.sameSceneWindow` is set to 3 minutes on judgement, not measurement. If
`.similar` still misses burst sequences it should go up; if it over-groups it should
come down. It is the first dial to reach for.

---

## Privacy

- No network code anywhere in the app. `isNetworkAccessAllowed` is hard-coded `false`
  on every PhotoKit request, including the ones that load images for display.
- Qdrant Edge runs in-process and its server-sync feature is not used. Its Rust
  workspace does compile HTTP and object-storage crates (for snapshot download), so
  the shipped binary was checked: a Release build imports no socket, DNS, TLS or
  `Security` symbols (`nm -u`) and contains no cloud endpoint strings. Re-check after
  bumping the Qdrant commit.
- Assets whose full-resolution pixels live only in iCloud are **counted and reported**
  in the UI, never silently skipped.
- Deletion goes through `PHAssetChangeRequest.deleteAssets`, so items land in
  **Recently Deleted and stay recoverable for 30 days**. There are two confirmations:
  the app's own sheet, then iOS's ("Allow OneShot to delete N photos?"). Verified in
  the simulator — the system sheet appears there too.

---

## Project layout

```
OneShot/
├── Models/          Value types: AssetRecord, Fingerprint, DuplicateGroup, ScanSource, Tuning
├── Engine/          Detection pipeline (no SwiftUI)
│   ├── AssetLoader            routes each id to the photo library or a folder
│   ├── PhotoLibraryService    PhotoKit: fetch, decode, delete
│   ├── FolderLibraryService   the same for a picked folder: list, decode, trash
│   ├── Fingerprinter          dHash, histogram, shape signature, sharpness, exposure
│   ├── VideoFingerprinter     keyframe sampling
│   ├── CandidateIndex         exhaustive pair generation
│   ├── PairVerifier           direct routes, Qdrant grey zone, Qdrant neighbour search
│   ├── VectorIndex            Qdrant Edge shard: shapes, pair scores, stored neighbours
│   ├── ClusterRefiner         star clustering
│   ├── FaceAnalyzer           face count, eyes-open estimate
│   ├── QualityScorer          keeper selection
│   ├── FingerprintStore       SQLite cache
│   └── DuplicateScanner       orchestration
└── Views/           SwiftUI, with LibraryModel as the single source of truth

OneShotTests/        Ground truth against a real Qdrant Edge shard; synthetic corpus generator
Packages/QdrantEdge/ Local Swift package: generated binding + XCFramework (both built, not committed)
Scripts/             build-qdrant-edge.sh
Design/              App icon source artwork, and PrepIcon.swift which crops it to AppIcon1024.png
```

## Building

Qdrant Edge has no released Swift package yet, so it is built from source once,
before the project will compile:

```bash
Scripts/build-qdrant-edge.sh
```

It clones a pinned commit of Qdrant's Swift SDK pull request, cross-compiles the
Rust engine for iOS devices and the Apple-silicon simulator with a pinned nightly
toolchain, generates the Swift binding with UniFFI and assembles
`Packages/QdrantEdge/QdrantEdge.xcframework`. Allow about 10 minutes and several GB
in `.build/qdrant-edge` (pass `--prune` on a tight disk). Later runs reuse the built
slices and finish in seconds.

It needs `rustup`; the toolchain and iOS targets are installed on demand. The
XCFramework is ~330 MB per slice as a static library, but linking strips it: Qdrant
adds about **22 MB** to the Release binary (31.9 MB in all).

## Tuning

Every threshold lives in `Tuning` in `Models/ScanSettings.swift`. The user-facing
control is the three-level `Sensitivity` enum — raw Hamming distances would be
meaningless to a user, so they never see one.

# Running OneShot on your iPhone

The project already builds and signs successfully for a physical device with your
Apple ID team (`GL3T359V25`), so this should be short.

**Requirements:** iPhone on iOS 26 or later, a Lightning/USB-C cable, Xcode 26 or later.

---

## 1. Open the project

From this `iOS` folder:

```bash
open OneShot.xcodeproj
```

## 2. Plug in your iPhone and pick it as the destination

Connect the phone, unlock it, and tap **Trust** if it asks. Then choose it from the
destination menu in the Xcode toolbar (next to the scheme name, where it currently
says a simulator).

If the device shows as unavailable, it usually needs one of: unlocking, enabling
Developer Mode (**Settings → Privacy & Security → Developer Mode**, then restart), or
letting Xcode finish "Preparing device for development".

## 3. Check the signing team

Select the **OneShot** target → **Signing & Capabilities**. "Automatically manage
signing" should be ticked with your team selected. It's already set in the project
file, so this is just a confirmation.

If you hit a bundle-identifier collision, change `PRODUCT_BUNDLE_IDENTIFIER` from
`com.rahil.OneShot` to something else unique — anything, e.g. `com.rahil.OneShot2`.

## 4. Build and run

Press **⌘R**.

Or from the terminal, in this `iOS` folder:

```bash
xcodebuild -project OneShot.xcodeproj -scheme OneShot -destination 'generic/platform=iOS' -configuration Release build
```

## 5. Trust the certificate on the phone

The first launch from a free Apple ID will refuse to open. On the iPhone go to
**Settings → General → VPN & Device Management**, tap your developer certificate, and
tap **Trust**. Then open OneShot again.

## 6. First run

Tap **Allow Full Access** at the photo prompt. Limited access won't work — a
duplicate is a relationship between two photos, so the app can't tell you something
is a copy if it can only see one of the pair.

Then tap **Scan Library**.

---

## What to expect

The first scan decodes every photo and is the slow one — budget roughly a minute per
few thousand items, longer if you have a lot of video, since each clip has five
keyframes sampled. Later scans only look at what changed and are much faster.

Leave the app in the foreground for the first scan; iOS will suspend the work if you
background it.

**Start at the default "Near-identical" setting.** That's the one calibrated against
ground truth, and it's the recommended balance. "Similar scenes" is deliberately
aggressive — it's for burst frames and shots of the same subject, and it needs real
review before you delete anything.

Nothing is deleted until you tap **Delete** and confirm, twice — once in the app and
once at the iOS prompt. Everything deleted goes to **Recently Deleted in Photos and
stays recoverable for 30 days**, so a mistake costs you a trip to that album, not a
photo.

Photos that live only in iCloud and aren't downloaded to the phone are skipped and
reported in the results, because the app never uses the network. If you want those
included, in Photos set **Settings → Photos → Download and Keep Originals** and let
it finish first.

---

## A note on free Apple ID accounts

If you're using a free Apple ID rather than a paid developer account, the app expires
after **7 days** and you'll need to rebuild from Xcode to keep using it. A paid
account extends this to a year. Nothing in the app depends on this — it's just how
Apple's signing works.

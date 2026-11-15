# Alpha playtesting guide

PocketDex is in **alpha**. The goal of this doc is to help you (the developer) recruit testers and help testers install a build and send useful feedback.

## Reality check: iOS can’t just “download any IPA”

| Method | Who can install | Effort | Best for |
|--------|-----------------|--------|----------|
| **TestFlight** (recommended) | Anyone you invite (email / public link after Apple beta review) | Medium — App Store Connect | Real playtesters |
| **Ad hoc IPA** | Only devices whose **UDIDs** you registered, then rebuilt | Medium per batch | Friends / small group |
| **Development IPA** (what `build_ipa.sh` makes by default) | Same as ad hoc — registered devices on your team | Low for you | Your own phone |
| **Sideloadly / AltStore** (tester uses *their* Apple ID) | That tester’s devices, ~7-day refresh | Low for you, annoying for them | Techy testers only |

**Bottom line:** Put the **source** on GitHub so people can see the project. Use **TestFlight** (or a small ad-hoc UDID list) for the actual app binary. A random IPA on a Releases page will **not** open on most people’s iPhones.

### Quick TestFlight path (overview)

1. Apple Developer account (you already have a team id for device builds).
2. Create the app in [App Store Connect](https://appstoreconnect.apple.com).
3. Archive in Xcode → **Distribute App** → **App Store Connect** (or upload the archive).
4. In TestFlight, add **Internal** testers (App Store Connect users) immediately, or **External** testers (needs a short Beta App Review the first time).
5. Share the TestFlight invite link / redeem code in your playtest post.

### Small friend group without TestFlight

1. Ask each person for their device **UDID** (Settings → General → About, or Xcode / Apple Configurator / [udid.tech](https://udid.tech)-style helpers).
2. Register those devices in the Apple Developer portal.
3. Rebuild/export an **Ad Hoc** IPA including those devices.
4. Host the IPA (GitHub Release, Diawi, etc.) and send the link + trust instructions.

---

## Copy-paste: message for Discord / Reddit / group chats

Use or edit this when recruiting people:

---

**Looking for alpha playtesters — PocketDex (iOS)**

Hey — I’m looking for a few people to try **PocketDex**, an early **alpha** iOS app for playing GB/GBC/GBA/DS Pokémon games and ROM hacks on iPhone, with extras like widescreen **Expand** on supported titles, a live companion HUD, and a save editor on optimized games.

**Please read this before jumping in:**

- This is **alpha**. A lot is unfinished, broken, or rough. I’m sharing it to learn what matters to players — not because it’s “done.”
- **Not affiliated with Nintendo / The Pokémon Company / Game Freak.** Bring **your own** legally obtained ROMs. I can’t and won’t provide games.
- **Large parts of this project were built with help from AI coding tools** (under my direction). I’m being upfront about that. Expect weird bugs; please report them instead of assuming it’s a polished commercial app.
- Install will be via **TestFlight** or a **registered-device IPA** (iOS doesn’t allow free universal IPA installs). I’ll share the link / ask for your UDID depending on the method.

**Optimized / best-supported titles right now**  
(These get the full play stack where noted: Expand widescreen, Companion HUD, save editor, etc. Other ROMs may still boot — they just won’t be “optimized.” Bring your own dumps; I don’t provide ROMs.)

**Retail Gen 3 (GBA)**  
- Pokémon Emerald  
- Pokémon FireRed  
- Pokémon LeafGreen  
- Pokémon Ruby  
- Pokémon Sapphire  

**FireRed hacks**  
- Pokémon Radical Red  
- Pokémon Unbound  
- FireRed Rocket Edition  
- Crystal Advance Redux  

**Emerald hacks**  
- Emerald Seaglass  
- Pokémon Heart and Soul  
- Pokémon R.O.W.E.  
- Pokémon SoulGold (GBA)  
- Pokémon Modern Emerald *(Companion + save editor; Expand not available for this dump yet)*  

**GB / GBC**  
- Pokémon Red / Blue / Yellow  
- Pokémon Green (Midori, JP)  
- Pokémon Crystal  
- Polished Crystal  

**Nintendo DS**  
- HeartGold / SoulSilver  
- Pokémon Platinum  

If you play one of the above, please say which version/build when you report bugs (e.g. Radical Red 4.1, Unbound 2.1.x, Seaglass 3.0).

**What I want from you**

- Device model + iOS version  
- Which game/hack you tried (ideally from the optimized list)  
- What felt good / confusing / broken  
- Crashes, audio issues, save problems, Expand/companion bugs  

**Repo (source, alpha notes):**  
https://github.com/anonxcast/PocketDex-iOS  

Thanks — even a short “tried X, Y was busted, Z was cool” message helps a lot.

---

## What feedback helps most

**High value**

- Crash + what you tapped before it happened  
- Wrong names/sprites in companion or save editor  
- Audio (slow, crackle, mute)  
- Expand not engaging / wrong zoom  
- Save file corruption or “Bad Egg” after using the editor  
- “I couldn’t figure out how to …” (onboarding / UX)

**Low value**

- “Add every hack” with no dump details  
- ROM requests  
- Feature essays without saying what you actually tried  

## Privacy

Don’t send full save files with personal cloud tokens. Screenshots of the UI are fine. If a save is needed to debug, say so in an issue and wait for instructions.

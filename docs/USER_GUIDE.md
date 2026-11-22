# Sing! user guide

Sing! turns a Mac (a Mac mini under the TV is ideal) into a karaoke machine. Phones, iPads and Android tablets in the room pick songs, and the TV shows the lyrics. Everything runs on the Mac: no account, no subscription, no server.

## 1. Set up the Mac

1. Open `Sing-<version>.dmg` and drag Sing! to Applications. The first launch copies the AI models (vocal separation, melody, singer detection) next to your data.
2. Allow the microphone when macOS asks. If the mic stays silent later, use Now Playing, Reset microphone permission.
3. Connect the TV by HDMI. Sing! shows the TV window on the second screen by itself; you can also pick the screen in Settings, TV.
4. Add music: drop files or folders on Library (MP3, FLAC, WAV, AAC, ALAC). Or choose a watch folder in Settings, Library: anything saved there is imported automatically.

Each song is prepared once: the voice is separated from the music, lyrics are found and timed word by word, the melody is analysed for the pitch guide and the score. Songs in the queue go first; the rest of the library is prepared in the background, and overnight during the nightly upkeep.

## 2. Join from phones and tablets

- **iPad, iPhone, Android app**: open Sing!, pick the Mac in the list or scan the QR code on the TV.
- **Any phone without the app**: scan the QR code on the TV; the web remote opens in the browser.
- **Codes**: guests use the code on the TV. Host devices (the ones that control playback and settings) use the host code in the Mac's Pads screen.
- **Android app**: a phone can download it from the Mac at `http://<mac address>:47800/sing.apk`.

Pick who you are (or create your profile) so your songs, stats and suggestions follow you. A profile can have a PIN so nobody else queues as you.

## 3. Sing

- **Search** any song or artist. Songs not on the Mac yet can be requested; the host sees requests in the queue. Other ways to search:
  - Hum the tune (the microphone button).
  - Type a line you remember (Lyric line).
  - Ask in plain words, like "a slow French duet" (✨ Ask).
- **Queue** a song for yourself, for two (duet), or as a battle where you take turns line by line. Singers take turns in the queue unless the host turns that off.
- **The TV** shows the lyrics with the words lighting up as you sing. It can also show the next lines, a pitch guide and a live score, all of which can be turned off. Translation and Latin spelling for other alphabets are available too.
- **After each song** the score appears with its details, an applause meter, and, when recording is on, a QR code to take the performance home.
- **Teleprompter** (Now Playing, on a pad or phone) shows the lyrics full screen on the device in your hand.
- **Use this device as a mic** (Settings) turns a phone into a wireless mic. It is experimental: keep it away from the speakers.

## 4. Host controls

From the Mac or a host pad:

- **Mixer**: guide vocal level, music and mic volume, key (±6 semitones), tempo, mic effects (Natural, Studio, Concert hall, Stadium, Echo, Radio), echo, light pitch correction, and a practice loop.
- **Several mics**: plug in a multichannel interface or several USB mics; each singer is scored on their own mic, and each mic can have its own volume.
- **Singer's headphones**: Settings, Audio, Singer's headphones sends the song with guide vocal to a second output.
- **Quick settings**: Party, Family (family mode, easy scoring) and Practice (no numbers, no history). You can save your own.
- **Song settings** (Library, right click): lyric timing, guide vocal, key, tempo, hide in family mode, keep stems. Edit Lyric Timing opens the sync editor: play the song and press Space as each line starts.
- **Wrong lyrics**: report them from a pad; the Mac sets them aside and looks again.

## 5. Owner area

Settings, Owner sets an owner PIN. Host pads then need it for:

- Storage: what Sing! uses, limits, clearing caches by category, by song or for songs not sung in a while.
- Paired devices: unpair, and the maximum number of devices.
- Lyrics sources and their order, processing limits, network name and port.
- Privacy and who can change which settings.
- AI models and the activity log.

Five wrong PINs lock a device out for a while.

## 6. Keeping it healthy

- **Backups**: the history, singers, favorites and settings are backed up every day; the last seven are kept. Settings, Backups also exports a copy.
- **Clap test**: Settings, Upkeep and tools, Run the clap test measures the room's delay so scores and recordings line up.
- **Moved music**: Find moved music relinks songs whose files moved. Check caches rebuilds anything damaged.
- **Erase everything** keeps your music files and starts over.
- **Logs**: crash and error logs stay on the Mac, under Show logs.

## 7. Optional: your own lyrics server

Sing! is complete on its own. If you run the Sing lyrics backend (see `sing-lyrics-infra/docs/SELF_HOSTING.md`), turn on "Sing lyrics database" in Settings, Lyrics sources and give its address. "Share AI-synced and fixed lyrics" then sends songs timed by the Mac to it, signed with the Mac's own key.

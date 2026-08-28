# Google Drive backup — what's configured

**Status: done, published, and verified on the phone.** The Cloud project
exists, the credentials are created, the app is in production, and the
**Back up to Google Drive** screen works end to end. Nothing is outstanding.

---

## What exists

| Thing | Value |
|---|---|
| Cloud project | `Field Notes` — `field-notes-506920` |
| Drive API | Enabled |
| Scope | `https://www.googleapis.com/auth/drive.appdata` (**non-sensitive**) |
| Publishing status | **In production** (published 28 Aug 2026 — no verification required) |
| Web client ID | `447000916304-t5mglcl7s586up04oobapom5sqiukkoq.apps.googleusercontent.com` |
| Android client (release) | package `io.nativeplanet.field_notes`, SHA-1 `8E:60:9F:8F:7E:C3:DA:64:56:B2:DE:B8:67:80:A7:C0:27:B6:23:80` |
| Android client (debug) | same package, SHA-1 `93:A9:6E:0F:2D:16:51:4E:25:B6:C5:54:84:1A:59:E3:AB:7E:73:E5` |

The Web client ID lives in `app/lib/backup/drive_auth.dart`. It is not a
secret — it names the app and authorises nothing on its own. There is a client
*secret* too; the app does not use it and it is not in the repo.

**Why two clients.** Google's Android libraries want both. The Android client
(matched by package name and signing fingerprint) proves a request came from
your build; the Web client is the identity string that build presents. There is
no website involved.

---

## What it does on the phone

Settings → Backup → **Back up to Google Drive** → Connect. You approve one
permission, and backups go to a folder Drive creates for this app.

That folder — `appDataFolder` — is not the same thing as "a folder in your
Drive". It does not appear in your file list, no other app can open it, and
the app cannot see anything that was already in your Drive. It is a private
box, not a key to the house.

What lands in it is the same encrypted blob store as every other backup
target. The phone seals every object before upload, so Google holds ciphertext
with meaningless names and no key. Losing your phone loses nothing; losing
your passphrase *and* your 12-word recovery kit loses everything, and that is
the trade you chose when you set the backup up.

Revoke any time at **myaccount.google.com/permissions**. The app keeps
working; it just stops uploading.

---

## Publishing status: done

The app is **in production**. Two static pages on shortsfieldstation.org
satisfied Google's requirement:

| Field | Value |
|---|---|
| Application home page | `https://shortsfieldstation.org/fieldnotes` |
| Application privacy policy | `https://shortsfieldstation.org/fieldnotes/privacy` |
| Authorized domain | `shortsfieldstation.org` |

Both pages are deliberately **unlisted** — `noindex`, absent from the
sitemap, not linked from the site nav — on the same pattern as `/support`.
They resolve for anyone with the URL, which is all Google needs, without
competing in search while the app isn't ready to hand to strangers.

Because `drive.appdata` is a **non-sensitive** scope, and the project has
one authorized domain and no uploaded logo, publishing required **no
verification and no security assessment**. The seven-day Testing-mode
sign-in expiry is gone.

Verified end to end on the Pixel: sign-in with no "unverified app" warning,
consent showing only "See, create, and delete its own configuration data in
your Google Drive", and three real backup generations to the app folder.

## If something goes wrong

- **"Developer error" / code 10** — the SHA-1 doesn't match the build on the
  phone. Both release and debug clients are registered, so this most likely
  means the app was signed with a different keystore. Check
  `~/.keystores` is the one in use.
- **"This app isn't verified"** — should not appear now that the app is in
  production with a non-sensitive scope. If it does, check the console hasn't
  been reverted to Testing.
- **Sign-in worked, then stopped about a week later** — this was the Testing-mode
  expiry and no longer applies now that the app is in production. Reconnect.
- **"Google sign-in expired. Open Backup and connect again."** — the app's own
  wording for a 401. Same fix.
- **"This Google account is out of Drive storage."** — the backup is real data
  and it counts against the account's quota.

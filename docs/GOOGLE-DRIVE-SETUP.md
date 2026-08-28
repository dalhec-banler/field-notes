# Google Drive backup — what's configured, and the one thing left

**Status: done and wired up.** The Cloud project exists, the credentials are
created, and the app has a working **Back up to Google Drive** screen. You do
not need to do anything in the console to use it.

There is one loose end — publishing status — described at the bottom.

---

## What exists

| Thing | Value |
|---|---|
| Cloud project | `Field Notes` — `field-notes-506920` |
| Drive API | Enabled |
| Scope | `https://www.googleapis.com/auth/drive.appdata` (**non-sensitive**) |
| Publishing status | **Testing** — `austinnelsen@gmail.com` is a test user |
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

## The one thing left: Testing → Production

The app is in **Testing** mode. That works today because your address is on
the test-user list, with one annoyance: **a sign-in expires after seven days**
and you reconnect. For a backup that runs daily, that means a tap roughly
weekly.

Moving to Production removes the expiry. Google requires two things first that
Field Notes does not have yet:

1. An **application home page** URL
2. A **privacy policy** URL

Both must be on a domain registered under *Authorized domains* in the console.
Any hosted page works — a GitHub Pages site under `dalhec-banler`, a page on
an existing domain, anything public and stable. Two static pages is the whole
job.

Because `drive.appdata` is a **non-sensitive** scope, that's all it takes:
Production here does *not* trigger the third-party security assessment that
full-Drive access requires. Once those URLs exist:

1. Console → **Branding** → fill in Application home page and Application
   privacy policy link → Save
2. **Audience** → **Publish app**

Two minutes. Until then, Testing is fine.

---

## If something goes wrong

- **"Developer error" / code 10** — the SHA-1 doesn't match the build on the
  phone. Both release and debug clients are registered, so this most likely
  means the app was signed with a different keystore. Check
  `~/.keystores` is the one in use.
- **"This app isn't verified"** — expected in Testing. *Advanced* → *Go to
  Field Notes*.
- **Sign-in worked, then stopped about a week later** — the seven-day Testing
  expiry above. Reconnect, or finish the Production step.
- **"Google sign-in expired. Open Backup and connect again."** — the app's own
  wording for a 401. Same fix.
- **"This Google account is out of Drive storage."** — the backup is real data
  and it counts against the account's quota.

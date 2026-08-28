# Setting up Google Drive backup — what Austin needs to do

Everything here happens in a browser, once. It takes about fifteen minutes.
You are creating a *permission slip* that lets Field Notes write to a hidden
folder in your own Drive — nothing else in your Drive, and nobody else's.

Two facts to keep in mind:

- **Google is not being given your records.** You are giving *your copy of
  Field Notes* permission to put files in *your* Drive. The scope we use,
  `drive.appdata`, can only see a private folder it creates for itself. It
  cannot read your documents, photos, or anything you already have.
- **You do not need Google to review or approve anything** while this is
  just you. Approval ("verification") only matters if this ships to
  strangers. Until then you add yourself as a test user and it works.

You'll paste two values back to me at the end. Neither is a password.

---

## The values you'll need (already worked out)

| What | Value |
|---|---|
| Package name | `io.nativeplanet.field_notes` |
| SHA-1, release build | `8E:60:9F:8F:7E:C3:DA:64:56:B2:DE:B8:67:80:A7:C0:27:B6:23:80` |
| SHA-1, debug build | `93:A9:6E:0F:2D:16:51:4E:25:B6:C5:54:84:1A:59:E3:AB:7E:73:E5` |

A SHA-1 fingerprint is just a checksum of the key your app is signed with.
Google uses it to be sure a request really comes from *your* app and not
something impersonating it. It is not secret — it's fine in this file.

---

## Step 1 — Make a project

1. Go to **console.cloud.google.com** and sign in with the Google account
   whose Drive you want backups in.
2. At the top of the page there's a project dropdown (it may say
   "Select a project"). Click it, then **New project**.
3. Name it `Field Notes`. Leave organisation/location as they are.
4. Click **Create**, then make sure that project is the one selected in the
   dropdown before you carry on. Everything after this happens *inside* it.

A "project" is just a container for settings. Nothing is running, nothing
is billed.

---

## Step 2 — Turn on the Drive API

1. In the search bar at the top, type **Google Drive API** and open it.
2. Click **Enable**.

That's it. You've said "this project is allowed to talk to Drive."

---

## Step 3 — Fill in the consent screen

This is the screen you'll see on your phone that says "Field Notes wants
access to…". Google needs to know what to put on it.

1. Search for **OAuth consent screen** (it may appear under *Google Auth
   Platform* → *Branding*) and open it.
2. Choose **External** if asked. (*Internal* is only for Google Workspace
   organisations. External does not mean public — it stays private until
   you publish it.)
3. Fill in:
   - **App name:** `Field Notes`
   - **User support email:** your email
   - **Developer contact email:** your email
   - Skip the logo and the links.
4. Save.
5. Find the **Audience** (or *Test users*) section. Make sure the publishing
   status is **Testing**, and click **Add users** — add your own Google
   address. Add any other address that will use the app.

> **Why Testing is the right setting.** In Testing mode, only the addresses
> you list can use it, and Google requires no review. The one quirk: a
> sign-in expires after seven days and you sign in again. When you're ready
> to hand this to other people, you switch to Production and go through
> basic verification — `drive.appdata` is a *non-sensitive* scope, so it's
> the light version, not the security audit that full-Drive access needs.

6. If there's a **Data access** or *Scopes* section, click **Add or remove
   scopes**, paste this into the filter box, tick it, and save:

   ```
   https://www.googleapis.com/auth/drive.appdata
   ```

   If you can't find it, skip this — the app asks for the scope itself.

---

## Step 4 — Create two credentials

You need two, and the reason is genuinely confusing, so: the **Android**
one proves the request came from your app; the **Web** one is the identity
string the app hands to Google. Google's own libraries want both, even
though there's no website involved.

Go to **Credentials** in the left menu.

**4a. The Android one**

1. **Create credentials** → **OAuth client ID**.
2. Application type: **Android**.
3. Name: `Field Notes Android`.
4. Package name: `io.nativeplanet.field_notes`
5. SHA-1: `8E:60:9F:8F:7E:C3:DA:64:56:B2:DE:B8:67:80:A7:C0:27:B6:23:80`
6. **Create**. There's no secret to copy — that's normal for Android.
7. *(Optional but useful)* Repeat 1–6 with the **debug** SHA-1
   (`93:A9:6E:...`) and the name `Field Notes Android (debug)`, so
   development builds work too.

**4b. The Web one**

1. **Create credentials** → **OAuth client ID** again.
2. Application type: **Web application**.
3. Name: `Field Notes Web`.
4. Leave the redirect URIs empty.
5. **Create**.
6. Copy the **Client ID**. It looks like:

   ```
   123456789012-abcdefghijklmnop.apps.googleusercontent.com
   ```

---

## Step 5 — Send me

- The **Web client ID** from 4b.

That's all. It is not a password and not a secret — it identifies the app,
it doesn't authorise anything on its own. Confirm you added the Android
client too, and I'll wire up the rest.

---

## What happens after

You'll get a **Google Drive** option on the Backup screen. Tapping it opens
the normal Google sign-in, you approve the one permission, and backups start
going to a hidden folder in your Drive that only Field Notes can see. The
files there are the same encrypted blobs as everywhere else — Google stores
them, Google cannot read them, and neither can we.

You can revoke it any time at **myaccount.google.com/permissions**, and the
app keeps working exactly as before, backing up locally.

---

## If something goes wrong

- **"Error 400: redirect_uri_mismatch"** — you're using the Web client where
  the Android client should be. Tell me; it's my side.
- **"This app isn't verified"** — expected in Testing. Click *Advanced* →
  *Go to Field Notes*. Or check your address is in the test-user list.
- **Sign-in worked, then stopped a week later** — that's the seven-day
  Testing-mode expiry. Sign in again, or switch to Production.
- **"Developer error" / code 10** — the SHA-1 doesn't match the build on the
  phone. Usually means the debug client is missing. Send me the error and
  I'll check which build you're running.

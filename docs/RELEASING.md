# Releasing

How to build the installer customers download, and how to publish it to the website.

```sh
make installer      # → build/SpaceKit-<version>.pkg and .dmg (universal: Apple silicon and Intel)
```

Without signing settings this builds unsigned installers, fine for trying the installer on your own Mac.
Every other Mac refuses to open them: anything you sell must be signed with a Developer ID and notarized
by Apple.

## One-time setup

1. **Developer ID certificates.** In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list)
   for team AppRise Ventures Oy (`XW75F94L2B`), create a **Developer ID Application** and a
   **Developer ID Installer** certificate, then double-click both to add them to your keychain. (The
   *Apple Development* and *Apple Distribution* certificates are for development and the App Store, and
   can't sign apps distributed outside it.) Check with:

   ```sh
   security find-identity -v -p codesigning     # lists "Developer ID Application: …"
   security find-identity -v -p basic | grep "Developer ID Installer"
   ```

2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com)
   (Sign-In and Security → App-Specific Passwords), then store it in the keychain under a profile name:

   ```sh
   xcrun notarytool store-credentials spacekit-notary \
     --apple-id you@example.com --team-id XW75F94L2B --password <app-specific-password>
   ```

3. **Sparkle signing key** (in-app updates). Already done on the Mac that ran
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account spacekit`: the private key is in its login
   keychain, and its public half is `installer/sparkle-public-key.txt`, which every build puts in the app.
   **Back the private key up**, or no installed copy will accept an update signed by any other key:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account spacekit -x ~/Desktop/spacekit-sparkle-key
   ```

   Store that file in your password manager, then delete it. On a new Mac, import it with
   `generate_keys --account spacekit -f <file>`.

## Each release

1. Bump `static let version` in `Sources/SpaceKitCLI/SpaceKitCommand.swift`, and write what changed in
   `docs/releases/<version>.md` (short Markdown; the app shows it under *What's New*).
2. Build, sign, notarize and staple:

   ```sh
   APP_SIGN_IDENTITY="Developer ID Application: AppRise Ventures Oy (XW75F94L2B)" \
   INSTALLER_SIGN_IDENTITY="Developer ID Installer: AppRise Ventures Oy (XW75F94L2B)" \
   NOTARY_PROFILE=spacekit-notary \
   make installer
   ```

   Notarization usually takes a few minutes per file. If Apple rejects one, the script prints the
   `notarytool log` command that shows why.

3. Try it like a customer would: download the `.pkg` onto another Mac (or another user account), open it,
   and check that macOS doesn't warn about it. `spctl --assess --type install -vv build/SpaceKit-*.pkg`
   should say `accepted, source=Notarized Developer ID`.

4. Publish it to the website:

   ```sh
   DEPLOY_TARGET=root@<server>:<downloads folder> scripts/publish-installer.sh
   ```

   It uploads the installer and the release notes. The site immediately serves the highest version in
   that folder, to new buyers and as an update. Setup: [web/README.md](../web/README.md).

## How updates reach buyers

SpaceKit 0.3.0 and later update themselves with [Sparkle](https://sparkle-project.org):

- About once a day (Settings → Updates can turn it off), Sparkle reads `https://spacekit.studio/appcast.xml`,
  adding `?key=<license key>` when the buyer linked their purchase. The appcast always names the newest
  version. For a key Stripe confirms as paid, it includes a signed download link to the DMG (valid for a
  week) and the DMG's Sparkle signature; Sparkle shows the release notes, downloads, checks that the
  signature matches `SUPublicEDKey` and that the app is signed by the same Developer ID, replaces the app
  and relaunches it. Without a valid key, the update is informational: *Learn More* opens `/update`.
- `scripts/publish-installer.sh` signs the DMG (`sign_update`) and uploads the signature as
  `SpaceKit-<version>.dmg.sig`. Without that file the appcast never offers the download.
- The license key is the buyer's Stripe Checkout Session id. The download page shows it, with *Copy key*,
  *Copy download link* and *Download as .txt* buttons and a
  *Link to SpaceKit* button (`spacekit://activate?key=…`) that stores it in the app; it can also be pasted
  in Settings → Updates.
- SpaceKit 0.2.0 checked `GET /api/updates/latest` instead and sends buyers to `/update`, which still works.
  0.1.0 has no update check: those buyers get the newest version from their download page, which always
  serves it, or from `/update` with their key. Either way, one manual update brings them onto Sparkle.

## What the installer does

`SpaceKit-<version>.pkg` is a standard macOS Installer package (`installer/Distribution.xml`):

- It requires macOS 15 or later.
- It installs `SpaceKit.app` into `/Applications`, replacing an older version there. The bundle isn't
  relocatable, so Installer never "upgrades" a copy somewhere else, such as a `build/` folder.
- It links the bundled CLI as `/usr/local/bin/spacekit`, unless that name already belongs to something
  other than SpaceKit (`installer/scripts/postinstall`).
- Its welcome, license and finish screens come from `installer/resources/` and `LICENSE`.

`SpaceKit-<version>.dmg` holds the same app with a link to Applications, for drag-and-drop installs.

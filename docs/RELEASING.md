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

## Each release

1. Bump `static let version` in `Sources/SpaceKitCLI/SpaceKitCommand.swift`.
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

   The site immediately serves the newest `.pkg` in that folder. Setup: [web/README.md](../web/README.md).

## What the installer does

`SpaceKit-<version>.pkg` is a standard macOS Installer package (`installer/Distribution.xml`):

- It requires macOS 15 or later.
- It installs `SpaceKit.app` into `/Applications`, replacing an older version there. The bundle isn't
  relocatable, so Installer never "upgrades" a copy somewhere else, such as a `build/` folder.
- It links the bundled CLI as `/usr/local/bin/spacekit`, unless that name already belongs to something
  other than SpaceKit (`installer/scripts/postinstall`).
- Its welcome, license and finish screens come from `installer/resources/` and `LICENSE`.

`SpaceKit-<version>.dmg` holds the same app with a link to Applications, for drag-and-drop installs.

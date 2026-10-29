# Ente Auth for the macOS menu bar

A native menu bar app for your [Ente Auth](https://ente.io/auth) codes. It signs in to your Ente account, syncs your codes, and shows them one click from the menu bar. It only reads your vault. To add, edit, or delete codes, use the official Ente Auth app.

This project is not made by or affiliated with Ente.

## What it does

- Signs in with your Ente email and password, plus an email or authenticator code if your account asks for one. Passkeys aren't supported yet.
- Locks when your Mac sleeps or locks, and 15 minutes after you last opened it. Touch ID or your Mac password unlocks it.
- Keeps your session in the keychain and your codes in an encrypted cache, so it works offline.
- Copies a code on click or Return. Clipboard managers skip copied codes, and the app clears them after 30 seconds.
- Hides codes behind dots if you turn on **Hide Codes**. Hold Option to see them.
- Opens from anywhere with Option-Command-E.
- Searches names, accounts, notes, and `#tags`.
- Suggests codes for the app you came from, and for the website in your browser if you turn that on.

Right-click the menu bar icon for Sync Now, Lock, settings, and Sign Out.

Supports TOTP and Steam codes. HOTP codes are listed but not generated.

## How it works

The app reuses Ente's code and servers. A small Rust layer wraps Ente's own crates, `ente-accounts` for sign-in and `ente-auth` for codes, and the Swift app calls it through UniFFI. It talks to `api.ente.com`, the same server the official apps use.

Your codes stay end-to-end encrypted. The app downloads them encrypted, decrypts them on your Mac with keys derived from your password, and generates each code locally.

The Ente sources come from the commit of [ente-io/ente](https://github.com/ente-io/ente) pinned in `UPSTREAM_REV`.

## License

AGPL-3.0, because the app links Ente's AGPL-licensed code. See `LICENSE` and `NOTICE.md`.

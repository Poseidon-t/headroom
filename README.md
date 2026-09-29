# Headroom

A menu bar app for a Mac that has become slow. It shows memory, swap and free disk, lists the heaviest apps, and names each open Claude Code session and dev server so you can close the ones you forgot about.

I built it for my own 8 GB MacBook. On the day I wrote it, the Mac had 12 GB in swap because seven Claude Code sessions and several day-old dev servers were still open, and the disk was nearly full.

## What it does

- Warns in the menu bar when memory or disk gets tight, and shows RAM, swap and free disk in the menu.
- Lists the apps using the most memory, counting swapped memory too.
- Lists every Claude Code session by its conversation title, with its memory and whether it is busy or idle.
- Lists dev servers with their port, their folder and how long they have been idle.
- **Quick fix** clears caches and stops dev servers idle for over an hour. It never closes a Claude Code session, because that ends the conversation.

## Install

Requires macOS 15 and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Poseidon-t/headroom.git
cd headroom
./build.sh
```

`build.sh` compiles the app, checks it with its self-test and installs it to `/Applications`; `./build.sh --no-install` stops after the build.

To download a built copy instead, take `Headroom.zip` from [Releases](https://github.com/Poseidon-t/headroom/releases), unzip it and move `Headroom.app` to Applications. The app is not notarized, so macOS blocks it on the first open: right-click it, choose Open, then Open again.

## From a terminal

```sh
/Applications/Headroom.app/Contents/MacOS/Headroom --report
```

prints the same numbers as the menu.

## License

MIT

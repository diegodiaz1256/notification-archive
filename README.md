# Notification Archive

A searchable thirty-day archive of every notification this machine receives.

The Omarchy notification daemon keeps only the newest ten notifications,
because that set exists to be replayed as toasts. This plugin is the other
half: a panel over a SQLite database holding everything that arrived, long
after the toast is gone.

Summon it from the Omarchy menu ("Notification Archive"), or directly:

    omarchy-shell shell summon zeroge.notification-archive

## What it stores

Every notification the daemon finalizes, whether it expired on screen, was
dismissed, was clicked, or never appeared at all because a profile silenced
it. Silenced entries are marked, so "what did I miss while muted" is one
filter away.

Icons are not copied. The daemon's own image copies are deleted when its
ten-entry history rolls over, so the archive stores the icon as it arrived: a
themed name stays resolvable forever, and an absolute path keeps working as
long as the app is installed. Where neither survives, the app's own name is
tried as a themed icon.

## First run

An empty archive is seeded once with five example entries, badged `example`,
that demonstrate pinning, notes, groups and a silenced entry. They are only
ever placed into an archive that has never held anything, so they cannot
appear among real notifications, and deleting them is permanent: the fact
that they were placed is recorded separately from whether any still exist.

Remove them together with:

    bin/notification-archive clear --samples

## Triage

- **Pin** an entry to keep it past the retention window.
- **Group** entries under a name. Anything in a group is also kept.
- **Note** an entry with free text, which is searchable alongside the body.
- **Delete** one entry, or clear what is currently filtered.

Pinned and grouped entries are never removed by retention. Everything else is
dropped thirty days after it arrived.

## Avatars

Some senders attach a sender image, such as a contact photo, that the shell
shows on the toast and then loses. Brave does this for WhatsApp web
notifications. It sends the photo through the `image-path` hint, pointing at a
file in its own scoped `/tmp` directory, and deletes that directory seconds
after the notification closes. Other senders deliver raw pixels in the
`image-data` hint instead, which Quickshell turns into an in-process URL that
dies with the notification. Quickshell also strips both hints from what it
exposes to QML, so the shell cannot save the image itself.

`avatar-daemon/` is a small Rust daemon that watches the session bus as a
passive monitor and copies the `image-path` file promptly, before the sender deletes it, and
encodes `image-data` pixels to a PNG. It uses `BecomeMonitor`,
which is read-only: it never owns the notification bus name, so the shell's
own daemon keeps receiving and displaying everything exactly as before. If it
is not running, nothing changes except that avatars are not saved.

    cd avatar-daemon && cargo build --release
    cp notification-avatar-daemon.service ~/.config/systemd/user/
    systemctl --user enable --now notification-avatar-daemon

It idles at about 1 MB.

Files go to `~/.local/state/omarchy/notifications/avatars/`, deliberately not
the `images/` directory beside it: the shell sweeps that one at startup and
deletes anything without a matching notification JSON, which every avatar
would be.

Each file is named `avatar-<hash>.png`, where the hash is FNV-1a 64 of the
notification summary alone. The app name is left out because the shell
rewrites it (Brave shows up as "WhatsApp"), and the monitor observes the
`Notify` call while the notification id is only assigned in the reply. Two
messages with the same summary therefore share a file, which is what you want
for one contact: it is the same photo, kept current by the newer write. The
trade-off is that two senders with the same summary text share one avatar,
and the last write wins. The panels compute the same hash in QML.

An avatar is deleted thirty days after that sender was last seen, matching how
long the archive keeps entries, with a 500-file ceiling as a backstop.

## Keyboard

The panel is fully keyboard driven; typing goes to the search box and the
navigation keys are forwarded past it.

| Key | Action |
| --- | --- |
| `↑` `↓`, `Ctrl+K` `Ctrl+J` | Move the cursor |
| `PageUp` `PageDown` | Move by ten |
| `Ctrl+Home` `Ctrl+End` | First, last |
| `Enter` | Open the sending app |
| `Shift+Enter`, `Ctrl+Space` | Expand in place |
| `Ctrl+P` | Pin or unpin |
| `Ctrl+N` | Add or edit a note |
| `Ctrl+G` | File into a group |
| `Ctrl+D`, `Delete` | Delete |
| `Ctrl+U` | Unread only |
| `Tab`, `Shift+Tab` | Cycle the app filter |
| `Esc` | Back out one layer, then close |

## Search

The index is a trigram FTS5 table, so a query matches anywhere inside a word:
"eplo" finds "deploy failed". Tokens shorter than three characters are
ignored, since a trigram index cannot match them.

A query that matches nothing falls back to similarity scoring over the newest
entries, so a misspelling still finds its target. Those results are labelled
"closest matches" rather than presented as exact.

## Why a helper script

Quickshell has no SQLite binding, so all database work happens in
`bin/notification-archive`, a Python script that speaks JSON.

The panel keeps one helper process running rather than spawning one per
query. Starting Python and opening the database costs about 36 ms against
1-3 ms for a query itself, so a process per keystroke is the difference
between a search box that keeps up with typing and one that does not.
Measured at 20000 rows: about 5 ms per keystroke, 22 ms for the fuzzy
fallback.

The same script is usable by hand, which is the other reason it is a script:

    bin/notification-archive list --query deploy
    bin/notification-archive list --app Slack --pinned
    bin/notification-archive apps
    bin/notification-archive set <stem> --pinned true --note "chase this"
    bin/notification-archive group add follow-up <stem>
    bin/notification-archive delete <stem>
    bin/notification-archive prune

## Ingest

The daemon writes to the archive through three hooks in its own
`Service.qml`: when a popup leaves the screen for any reason, when a silenced
notification is recorded, and when a restored popup turns out to have expired
while the shell was down. Failure is silent and non-blocking by design, since
the archive is a convenience and must never stop a notification being shown.

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

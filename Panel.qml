// Notification archive: a searchable window over every notification received
// in the last thirty days.
//
// Summoned with `omarchy-shell shell summon zeroge.notification-archive`.
//
// The notification daemon keeps ten notifications, because that set exists to
// be replayed as toasts. Everything it finalizes is also written to a SQLite
// database by the daemon's archive hook; this panel is the reader for it.
//
// All database work happens in bin/notification-archive. The helper is kept
// running for the life of the panel rather than spawned per query: starting
// python and opening the database costs about 36 ms against 1-3 ms for a
// query, so a process per keystroke is the difference between a search box
// that keeps up with typing and one that does not.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  // Injected by the shell only when the property exists here, and the only
  // way a third-party plugin can resolve its own directory.
  property var pluginRegistry: null

  property bool opened: false

  property var entries: []
  property var apps: []
  property var groups: []
  property int total: 0
  property int unreadCount: 0
  property bool fuzzy: false
  property bool loading: false
  property string error: ""

  // Filter state. Every one of these re-runs the query.
  property string query: ""
  property string appFilter: ""
  property string groupFilter: ""
  property bool pinnedOnly: false
  property bool unreadOnly: false

  property int cursor: 0
  // Which entry has its detail row expanded, by stem. Only one at a time:
  // the point of the list is scanning many, not reading one.
  property string expanded: ""
  // Stem whose note is being edited, "" when none is.
  property string editingNote: ""

  readonly property string fontFamily: Style.font.family

  // Omarchy strips __sourceDir from a third-party plugin's manifest, so the
  // directory has to be recovered through the registry instead. Without this
  // the helper path resolves to "/bin/notification-archive", which does not
  // exist, and the panel silently shows nothing.
  readonly property string sourceDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    if (pluginRegistry && manifest) {
      var url = String(pluginRegistry.entryPointUrl(manifest, "panel") || "")
      var path = url.replace(/^file:\/\//, "")
      var cut = path.lastIndexOf("/")
      if (cut > 0) return path.substring(0, cut)
    }
    return ""
  }

  readonly property string helper: root.sourceDir + "/bin/notification-archive"

  function open(payloadJson) {
    // Every summon starts clean. The panel is long-lived and the database
    // moves underneath it -- notifications arrive, entries age out -- so
    // reopening has to re-read rather than repaint whatever the last session
    // left behind, which is how a stale count could sit above an empty list.
    root.entries = []
    root.total = 0
    root.unreadCount = 0
    root.query = ""
    root.appFilter = ""
    root.groupFilter = ""
    root.pinnedOnly = false
    root.unreadOnly = false
    root.expanded = ""
    root.editingNote = ""
    root.newGroupFor = ""
    root.cursor = 0
    root.error = ""
    root.opened = true
    // startHelper refreshes on its own once the helper answers "ready"; this
    // second call covers the case where it is already running from a previous
    // summon and will send no greeting.
    root.startHelper()
    root.refresh()
    root.send({ cmd: "groups" })
  }

  function close() {
    root.opened = false
    root.expanded = ""
    root.editingNote = ""
    // The helper holds an open database handle; it has nothing to do while
    // the panel is shut, so it is stopped rather than left resident.
    helperProc.running = false
  }

  function toggle() { root.opened ? root.close() : root.open() }

  // ------------------------------------------------------------- helper
  //
  // One long-lived process speaking one JSON object per line each way. Each
  // request carries a serial so a reply that arrives after the filters moved
  // on can be discarded rather than painting stale rows.

  property int requestSerial: 0
  property int pendingSerial: -1
  property var pendingKind: ""

  Process {
    id: helperProc
    running: false
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleReply(line) }
    }

    onExited: function(exitCode) {
      if (!root.opened) return
      root.loading = false
      // 127 is exec's "not found", which here means python3 is missing
      // rather than anything being wrong with the archive.
      root.error = exitCode === 127
        ? "This plugin needs python3, which is not installed"
        : "The archive helper stopped unexpectedly"
    }
  }

  function startHelper() {
    if (helperProc.running) return
    if (!root.helper || root.sourceDir === "") {
      root.error = "Could not locate the archive helper"
      return
    }
    root.error = ""
    helperProc.command = [root.helper, "serve"]
    helperProc.running = true
  }

  function send(request) {
    if (!helperProc.running) return
    helperProc.write(JSON.stringify(request) + "\n")
  }

  function handleReply(line) {
    var text = String(line || "").trim()
    if (!text) return

    var reply
    try {
      reply = JSON.parse(text)
    } catch (e) {
      return
    }

    // The greeting the helper sends once it has the database open.
    if (reply.ready) {
      root.refresh()
      return
    }

    if (!reply.ok) {
      root.loading = false
      root.error = String(reply.error || "The archive could not be read")
      return
    }

    if (reply.entries !== undefined) {
      root.loading = false
      root.error = ""
      root.entries = reply.entries || []
      root.total = reply.total || 0
      root.unreadCount = reply.unread || 0
      root.fuzzy = !!reply.fuzzy
      if (root.cursor >= root.entries.length) root.cursor = Math.max(0, root.entries.length - 1)
      return
    }

    if (reply.apps !== undefined) { root.apps = reply.apps || []; return }
    if (reply.groups !== undefined) { root.groups = reply.groups || []; return }

    // A mutation acknowledged: re-read so the list reflects it. The helper
    // is cheap to query, and re-reading avoids keeping a second copy of the
    // truth here that could drift from the database.
    if (reply.changed !== undefined || reply.deleted !== undefined || reply.group !== undefined) {
      root.refresh()
      root.send({ cmd: "groups" })
    }
  }

  function refresh() {
    if (!helperProc.running) return
    root.loading = true
    var request = { cmd: "list", limit: 300 }
    if (root.query) request.query = root.query
    if (root.appFilter) request.app = root.appFilter
    if (root.groupFilter) request.group = root.groupFilter
    if (root.pinnedOnly) request.pinned = true
    if (root.unreadOnly) request.unread = true
    root.send(request)
    root.send({ cmd: "apps" })
  }

  // Typing runs the query, but not on every keystroke: the helper answers in
  // about 5 ms, and a short debounce keeps a fast typist from queueing a
  // request per letter for results they are about to replace anyway.
  Timer {
    id: queryDebounce
    interval: 120
    repeat: false
    onTriggered: root.refresh()
  }

  onQueryChanged: queryDebounce.restart()
  onAppFilterChanged: root.refresh()
  onGroupFilterChanged: root.refresh()
  onPinnedOnlyChanged: root.refresh()
  onUnreadOnlyChanged: root.refresh()

  // --------------------------------------------------------- operations

  function entryAt(index) {
    if (index < 0 || index >= root.entries.length) return null
    return root.entries[index]
  }

  // Cursor movement is clamped rather than wrapped: wrapping from the last
  // entry back to the first reads as a jump when the list is long, and the
  // ends are where a user stops deliberately.
  function setCursor(index) {
    if (root.entries.length === 0) { root.cursor = 0; return }
    root.cursor = Math.max(0, Math.min(index, root.entries.length - 1))
    // Expanding follows the cursor when a row is already expanded, so arrowing
    // through a list in "read" mode keeps showing the body rather than
    // collapsing on the first keypress.
    if (root.expanded !== "") {
      var entry = root.entryAt(root.cursor)
      if (entry) {
        root.expanded = entry.stem
        root.markRead(entry)
      }
    }
  }

  function moveCursor(delta) {
    root.setCursor(root.cursor + delta)
  }

  // Steps through the apps the filter chips show, plus "no filter" as the
  // first stop, so Tab cycles the same set the mouse can click.
  function cycleAppFilter(direction) {
    if (root.apps.length === 0) return
    var names = [""]
    for (var i = 0; i < root.apps.length; i++) names.push(root.apps[i].app)
    var at = names.indexOf(root.appFilter)
    if (at < 0) at = 0
    var next = (at + direction + names.length) % names.length
    root.appFilter = names[next]
  }

  function togglePin(entry) {
    if (!entry) return
    root.send({ cmd: "set", stem: [entry.stem], pinned: entry.pinned ? "false" : "true" })
  }

  function markRead(entry) {
    if (!entry || !entry.unread) return
    root.send({ cmd: "set", stem: [entry.stem], unread: "false" })
  }

  function setNote(entry, text) {
    if (!entry) return
    root.send({ cmd: "set", stem: [entry.stem], note: String(text || "") })
  }

  function removeEntry(entry) {
    if (!entry) return
    root.send({ cmd: "delete", stem: [entry.stem] })
  }

  function addToGroup(entry, name) {
    if (!entry || !name) return
    root.send({ cmd: "group", action: "add", name: name, stem: [entry.stem] })
  }

  function removeFromGroup(entry, name) {
    if (!entry || !name) return
    root.send({ cmd: "group", action: "remove", name: name, stem: [entry.stem] })
  }

  // Clears what is currently listed, minus anything pinned or grouped, which
  // the helper refuses to delete without --force.
  function clearFiltered() {
    root.send({ cmd: "clear", app: root.appFilter || undefined })
  }

  // Focusing the sending app is the one action an archived notification can
  // still perform: its Notification object died with the toast, so there is
  // no stored action left to replay. The daemon already owns the window
  // matching, so this goes through its IPC rather than duplicating it.
  Process { id: focusProc; running: false }

  function focusApp(entry) {
    if (!entry || !entry.app) return
    focusProc.command = ["omarchy-shell", "notifications", "focusHistoryApp",
                         String(entry.app), String(entry.body || "")]
    focusProc.running = true
    root.markRead(entry)
    root.close()
  }

  // ------------------------------------------------------------ helpers

  // ------------------------------------------------------------ avatars
  //
  // Some senders deliver their image as raw pixels in the `image-data` hint
  // rather than as a file path (Brave does, for WhatsApp). Those pixels never
  // reach the shell's own storage: see avatar-daemon/, which captures them
  // off the bus and writes a PNG here.
  //
  // The daemon cannot know the notification id -- it watches the method call,
  // and the id is assigned in the reply -- so it names files after the sending
  // app and a hash of the summary. This recomputes that name to find the file.

  readonly property string avatarDir:
    Quickshell.env("HOME") + "/.local/state/omarchy/notifications/avatars/"

  // FNV-1a, 64-bit, matching avatar-daemon's fnv1a(). Carried as two 32-bit
  // halves because a JavaScript number cannot hold a 64-bit integer exactly,
  // and a rounded hash would name a file that does not exist.
  function fnv1a(text) {
    var hi = 0xcbf29ce4 >>> 0
    var lo = 0x84222325 >>> 0
    var bytes = root.utf8Bytes(String(text || ""))
    for (var i = 0; i < bytes.length; i++) {
      lo = (lo ^ bytes[i]) >>> 0
      // Multiply the 64-bit value by the FNV prime, 0x100000001b3, in 16-bit
      // pieces so no intermediate exceeds what a double represents exactly.
      var l0 = lo & 0xffff, l1 = lo >>> 16, h0 = hi & 0xffff, h1 = hi >>> 16
      var p0 = l0 * 0x01b3
      var p1 = l1 * 0x01b3 + (p0 >>> 16)
      var p2 = h0 * 0x01b3 + (p1 >>> 16)
      var p3 = h1 * 0x01b3 + (p2 >>> 16)
      var nlo = (((p1 & 0xffff) << 16) | (p0 & 0xffff)) >>> 0
      var nhi = (((p3 & 0xffff) << 16) | (p2 & 0xffff)) >>> 0
      // The prime's high word is 0x100, so the low half contributes this much
      // to the high half.
      nhi = (nhi + lo * 0x100) >>> 0
      lo = nlo
      hi = nhi
    }
    function hex8(value) {
      var out = (value >>> 0).toString(16)
      while (out.length < 8) out = "0" + out
      return out
    }
    return hex8(hi) + hex8(lo)
  }

  // The daemon hashes the summary's UTF-8 bytes, so a name with an accent in
  // it has to be encoded the same way rather than hashed as UTF-16 code units.
  function utf8Bytes(text) {
    var out = []
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 0x80) {
        out.push(code)
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
      } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        // Surrogate pair: combine into one code point before encoding.
        var low = text.charCodeAt(i + 1)
        var point = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
        out.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f),
                 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f))
        i++
      } else {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f),
                 0x80 | (code & 0x3f))
      }
    }
    return out
  }

  // The path the daemon would have written for this entry. Whether it exists
  // is left to the Image: a sender that never attached pixels simply has no
  // file, and the icon falls back to the app's own.
  function avatarPath(app, summary) {
    var safe = ""
    var name = String(app || "")
    for (var i = 0; i < name.length && safe.length < 40; i++) {
      var ch = name.charAt(i)
      safe += /[A-Za-z0-9]/.test(ch) ? ch : "-"
    }
    return root.avatarDir + "avatar-" + safe + "-" + root.fnv1a(summary) + ".png"
  }

  function iconSource(icon, app) {
    var value = String(icon || "")
    if (value.length === 0) {
      // Nothing stored: try the app's own name as a themed icon, which is
      // how most desktop entries are named anyway.
      var name = String(app || "").toLowerCase().replace(/\s+/g, "-")
      return name ? Quickshell.iconPath(name, true) : ""
    }
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function relativeTime(ms) {
    var deltaSec = Math.max(0, Math.round((Date.now() - Number(ms || 0)) / 1000))
    if (deltaSec < 60) return "just now"
    var deltaMin = Math.round(deltaSec / 60)
    if (deltaMin < 60) return deltaMin + " min ago"
    var deltaHour = Math.round(deltaMin / 60)
    if (deltaHour < 24) return deltaHour + (deltaHour === 1 ? " hour ago" : " hours ago")
    var deltaDay = Math.round(deltaHour / 24)
    return deltaDay + (deltaDay === 1 ? " day ago" : " days ago")
  }

  function dayLabel(ms) {
    var d = new Date(Number(ms || 0))
    var today = new Date()
    var yesterday = new Date(today.getTime() - 86400000)
    function sameDay(a, b) {
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate()
    }
    if (sameDay(d, today)) return "Today"
    if (sameDay(d, yesterday)) return "Yesterday"
    return Qt.formatDate(d, "d MMMM")
  }

  // True when this row starts a new day in the list, so the delegate can draw
  // a date heading above it. Pinned rows sort first and are not part of the
  // day run, so they are grouped under their own heading instead.
  function startsNewDay(index) {
    var entry = root.entryAt(index)
    if (!entry) return false
    var previous = root.entryAt(index - 1)
    if (!previous) return true
    if (entry.pinned !== previous.pinned) return true
    if (entry.pinned) return false
    return root.dayLabel(entry.timestamp) !== root.dayLabel(previous.timestamp)
  }

  function headingFor(index) {
    var entry = root.entryAt(index)
    if (!entry) return ""
    return entry.pinned ? "Pinned" : root.dayLabel(entry.timestamp)
  }

  Component.onCompleted: {
    if (root.opened) root.open()
  }

  // --------------------------------------------------------------- window

  PanelWindow {
    id: panelWindow
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-notification-archive"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
      anchors.fill: parent
      focus: true

      // Everything reachable by mouse is reachable from the keyboard, since
      // this panel opens over whatever the user was doing and reaching for
      // the mouse to triage a list is what makes it not worth opening.
      //
      // Typing goes to the search box, so the list keys are the ones a text
      // field does not want: arrows, Tab, and Ctrl chords. Plain letters stay
      // with the search field.
      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var entry = root.entryAt(root.cursor)

        // --- leaving ---
        if (event.key === Qt.Key_Escape) {
          if (root.newGroupFor !== "") root.newGroupFor = ""
          else if (root.editingNote !== "") root.editingNote = ""
          else if (root.expanded !== "") root.expanded = ""
          else if (root.query !== "") root.query = ""
          else if (root.appFilter !== "" || root.groupFilter !== ""
                   || root.pinnedOnly || root.unreadOnly) {
            root.appFilter = ""
            root.groupFilter = ""
            root.pinnedOnly = false
            root.unreadOnly = false
          } else root.close()
          event.accepted = true
          return
        }

        // While a note or group name is being typed, the list keys belong to
        // that field: Enter commits it, Escape above cancels it.
        if (root.editingNote !== "" || root.newGroupFor !== "") return

        // --- moving ---
        if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
          root.moveCursor(1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
          root.moveCursor(-1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_PageDown) { root.moveCursor(10); event.accepted = true; return }
        if (event.key === Qt.Key_PageUp) { root.moveCursor(-10); event.accepted = true; return }
        if (event.key === Qt.Key_Home && ctrl) { root.setCursor(0); event.accepted = true; return }
        if (event.key === Qt.Key_End && ctrl) {
          root.setCursor(root.entries.length - 1)
          event.accepted = true
          return
        }

        // --- acting on the row under the cursor ---
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (!entry) return
          // Enter opens the app, which is the one thing an archived entry can
          // still do; Shift+Enter expands it instead, for reading in place.
          if (event.modifiers & Qt.ShiftModifier) {
            root.expanded = root.expanded === entry.stem ? "" : entry.stem
            root.markRead(entry)
          } else {
            root.focusApp(entry)
          }
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Space && ctrl) {
          if (entry) {
            root.expanded = root.expanded === entry.stem ? "" : entry.stem
            root.markRead(entry)
          }
          event.accepted = true
          return
        }
        if (ctrl && event.key === Qt.Key_P) { root.togglePin(entry); event.accepted = true; return }
        if (ctrl && event.key === Qt.Key_N) {
          if (entry) { root.expanded = entry.stem; root.editingNote = entry.stem }
          event.accepted = true
          return
        }
        if (ctrl && event.key === Qt.Key_G) {
          if (entry) { root.expanded = entry.stem; root.newGroupFor = entry.stem }
          event.accepted = true
          return
        }
        if (ctrl && event.key === Qt.Key_D) { root.removeEntry(entry); event.accepted = true; return }
        if (event.key === Qt.Key_Delete) { root.removeEntry(entry); event.accepted = true; return }

        // --- filters ---
        if (ctrl && event.key === Qt.Key_U) { root.unreadOnly = !root.unreadOnly; event.accepted = true; return }
        if (ctrl && event.key === Qt.Key_L) {
          // Cycle the app filter with Tab-like stepping, so a keyboard user can
          // narrow to one sender without reaching for its chip.
          root.cycleAppFilter(1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Backtab
            || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
          root.cycleAppFilter(-1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab) {
          root.cycleAppFilter(1)
          event.accepted = true
          return
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(panelWindow.width - 80, 900)
        height: Math.min(panelWindow.height - 80, 820)
        radius: Style.cornerRadius
        color: Color.menu.background
        border.width: 1
        border.color: Color.menu.border

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.lg
          spacing: Style.spacing.md

          // ---------------------------------------------------- header

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: "󰂺"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: "Notification archive"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: root.unreadCount > 0
                ? root.entries.length + " of " + root.total + " · " + root.unreadCount + " unread"
                : root.entries.length + " of " + root.total
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------------------------------------------------- search

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(36)
            radius: Style.spacing.labelGap
            color: Color.menu.selectedBackground
            border.width: 1
            border.color: searchInput.activeFocus ? Color.accent : Color.menu.border

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "󰍉"
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextInput {
                id: searchInput
                Layout.fillWidth: true
                focus: root.opened
                color: Color.menu.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                selectByMouse: true
                clip: true
                onTextChanged: root.query = text
                // Typing belongs to this field, but navigation does not: the
                // list keys are forwarded up so the cursor can move while the
                // caret stays here and the next letter still lands in the
                // search box.
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Down || event.key === Qt.Key_Up
                      || event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp
                      || event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                      || event.key === Qt.Key_Escape || event.key === Qt.Key_Tab
                      || event.key === Qt.Key_Backtab || event.key === Qt.Key_Delete
                      || (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = false
                  }
                }

                // Cleared from outside (Escape) without fighting the cursor
                // while typing.
                Connections {
                  target: root
                  function onQueryChanged() {
                    if (root.query === "" && searchInput.text !== "") searchInput.text = ""
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: searchInput.text === ""
                  text: "Search everything received in the last 30 days"
                  color: Color.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.fuzzy
                text: "closest matches"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------------------------------------------------- filters

          Flow {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Repeater {
              model: {
                var chips = [
                  { id: "pinned", label: "󰐃 Pinned", active: root.pinnedOnly },
                  { id: "unread", label: "󰂚 Unread", active: root.unreadOnly }
                ]
                for (var i = 0; i < root.groups.length; i++) {
                  var g = root.groups[i]
                  chips.push({
                    id: "group:" + g.name,
                    label: "󰓹 " + g.name + " (" + g.count + ")",
                    active: root.groupFilter === g.name
                  })
                }
                for (var j = 0; j < root.apps.length && j < 8; j++) {
                  var a = root.apps[j]
                  chips.push({
                    id: "app:" + a.app,
                    label: a.app + " (" + a.count + ")",
                    active: root.appFilter === a.app
                  })
                }
                return chips
              }

              delegate: Rectangle {
                required property var modelData
                height: Style.space(24)
                width: chipLabel.implicitWidth + Style.space(18)
                radius: height / 2
                color: modelData.active
                  ? Color.menu.selectedBackground
                  : (chipMouse.containsMouse
                      ? Color.menu.selectedBackground
                      : "transparent")
                border.width: modelData.active ? 0 : 1
                border.color: Color.menu.border

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: modelData.active ? Color.menu.selectedText : Color.menu.text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var id = String(modelData.id)
                    if (id === "pinned") root.pinnedOnly = !root.pinnedOnly
                    else if (id === "unread") root.unreadOnly = !root.unreadOnly
                    else if (id.indexOf("group:") === 0) {
                      var g = id.substring(6)
                      root.groupFilter = root.groupFilter === g ? "" : g
                    } else if (id.indexOf("app:") === 0) {
                      var a = id.substring(4)
                      root.appFilter = root.appFilter === a ? "" : a
                    }
                  }
                }
              }
            }
          }

          // ---------------------------------------------------- states

          Text {
            Layout.fillWidth: true
            visible: root.error !== ""
            text: root.error
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: root.error === "" && root.entries.length === 0 && !root.loading
            text: root.total === 0
              ? "Nothing archived yet. Every notification you receive is kept here for 30 days."
              : "No match. Try fewer words, or clear the filters with Escape."
            color: Color.menu.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------------ list

          ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.entries
            spacing: Style.space(4)
            currentIndex: root.cursor
            boundsBehavior: Flickable.StopAtBounds
            // Without this the cursor can walk off the visible area and the
            // list appears frozen while the selection moves out of sight.
            highlightFollowsCurrentItem: true
            highlightMoveDuration: 90
            preferredHighlightBegin: height * 0.15
            preferredHighlightEnd: height * 0.85
            highlightRangeMode: ListView.ApplyRange

            delegate: Column {
              id: rowColumn
              required property var modelData
              required property int index
              width: list.width
              spacing: Style.space(4)

              readonly property bool isExpanded: root.expanded === modelData.stem
              // Checked once per row: FileView reports a missing file without
              // the warning an Image emits, and the answer decides whether the
              // avatar is even attempted.
              property bool avatarExists: false

              FileView {
                path: root.avatarPath(rowColumn.modelData.app, rowColumn.modelData.summary)
                blockLoading: false
                printErrors: false
                onLoaded: rowColumn.avatarExists = true
                onLoadFailed: rowColumn.avatarExists = false
              }

              Text {
                visible: root.startsNewDay(rowColumn.index)
                text: root.headingFor(rowColumn.index)
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                topPadding: Style.space(8)
                bottomPadding: Style.space(2)
              }

              Rectangle {
                width: parent.width
                // Follows the layout rather than a fixed guess, so expanding a
                // row (which adds the action buttons and unclamps the text)
                // actually makes room for what appears. Binding this to an
                // anchored child's implicitHeight left the extra content
                // drawn outside the row and clipped away by the ListView.
                height: entryBody.implicitHeight + Style.space(16)
                radius: Style.spacing.labelGap
                readonly property bool isCursor: root.cursor === rowColumn.index
                color: rowMouse.containsMouse || rowColumn.isExpanded || isCursor
                  ? Color.menu.selectedBackground
                  : "transparent"
                // A left edge marks where the keyboard is, distinct from the
                // fill a mouse hover paints, so the two are never confused.
                Rectangle {
                  visible: parent.isCursor
                  width: Style.space(2)
                  height: parent.height
                  anchors.left: parent.left
                  radius: width
                  color: Color.accent
                }

                // A thin accent bar marks an entry that never reached the
                // screen, so "I never saw this" is visible while scanning
                // rather than something to hunt for per row.
                Rectangle {
                  visible: rowColumn.modelData.silenced
                  width: Style.space(2)
                  height: parent.height - Style.space(12)
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  radius: width
                  color: Color.muted
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function(mouse) {
                    root.cursor = rowColumn.index
                    if (mouse.button === Qt.RightButton) {
                      root.focusApp(rowColumn.modelData)
                      return
                    }
                    root.expanded = rowColumn.isExpanded ? "" : rowColumn.modelData.stem
                    root.markRead(rowColumn.modelData)
                  }
                }

                RowLayout {
                  id: entryBody
                  x: Style.space(10)
                  y: Style.space(8)
                  width: parent.width - Style.space(18)
                  spacing: Style.space(10)

                  Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Style.space(2)
                    width: Style.space(26)
                    height: Style.space(26)
                    // Round for a captured avatar, which is a person, and
                    // square-ish for an app icon, which is a logo.
                    radius: entryAvatar.status === Image.Ready
                      ? width / 2
                      : Style.spacing.labelGap
                    color: Color.menu.selectedBackground
                    visible: entryAvatar.status === Image.Ready
                      || entryIcon.status === Image.Ready
                    clip: true

                    // The sender's own image, when avatar-daemon captured one.
                    // It identifies the contact rather than the app, so it
                    // wins over the app icon; the app icon shows through when
                    // there is no file, which is every sender that does not
                    // attach pixels.
                    Image {
                      id: entryAvatar
                      anchors.fill: parent
                      // Most senders attach no pixels, so most rows have no
                      // file here. Qt logs a warning per missing source, which
                      // would mean a line of shell log for every ordinary
                      // notification, so the path is only handed over once the
                      // file is known to exist.
                      source: rowColumn.avatarExists
                        ? root.avatarPath(rowColumn.modelData.app, rowColumn.modelData.summary)
                        : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                    }

                    Image {
                      id: entryIcon
                      anchors.fill: parent
                      anchors.margins: Style.space(4)
                      visible: entryAvatar.status !== Image.Ready
                      source: root.iconSource(rowColumn.modelData.appIcon, rowColumn.modelData.app)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: rowColumn.modelData.app || "Unknown"
                        color: Color.menu.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      // Says outright that a row is an example rather than
                      // something that arrived, so the first-run entries can
                      // never be read as notifications that were missed.
                      Rectangle {
                        visible: rowColumn.modelData.sample === true
                        width: sampleTag.implicitWidth + Style.space(8)
                        height: Style.space(15)
                        radius: Style.space(3)
                        color: "transparent"
                        border.width: 1
                        border.color: Color.accent

                        Text {
                          id: sampleTag
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: "example"
                          color: Color.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: rowColumn.modelData.pinned
                        text: "󰐃"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: rowColumn.modelData.note !== ""
                        text: "󰏫"
                        color: Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Repeater {
                        model: rowColumn.modelData.groups || []
                        delegate: Text {
                          required property string modelData
                          textFormat: Text.PlainText
                          text: "󰓹 " + modelData
                          color: Color.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Item { Layout.fillWidth: true }

                      Text {
                        textFormat: Text.PlainText
                        text: root.relativeTime(rowColumn.modelData.timestamp)
                        color: Color.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      visible: (rowColumn.modelData.summary || "") !== ""
                      text: rowColumn.modelData.summary
                      color: Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: rowColumn.modelData.unread
                      elide: Text.ElideRight
                      maximumLineCount: rowColumn.isExpanded ? 4 : 1
                      wrapMode: Text.WordWrap
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      visible: (rowColumn.modelData.body || "") !== ""
                      text: rowColumn.modelData.body
                      color: Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      maximumLineCount: rowColumn.isExpanded ? 12 : 1
                      wrapMode: Text.WordWrap
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      visible: rowColumn.isExpanded && rowColumn.modelData.note !== ""
                      text: "󰏫 " + rowColumn.modelData.note
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }

                    // ---- note editor ----
                    Rectangle {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(4)
                      visible: root.editingNote === rowColumn.modelData.stem
                      height: Style.space(30)
                      radius: Style.spacing.labelGap
                      color: Color.menu.selectedBackground
                      border.width: 1
                      border.color: Color.accent

                      TextInput {
                        id: noteInput
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        verticalAlignment: TextInput.AlignVCenter
                        color: Color.menu.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        selectByMouse: true
                        clip: true
                        onVisibleChanged: {
                          if (visible) {
                            text = rowColumn.modelData.note || ""
                            forceActiveFocus()
                          }
                        }
                        onAccepted: {
                          root.setNote(rowColumn.modelData, text)
                          root.editingNote = ""
                        }
                      }
                    }

                    // ---- actions, only on the expanded row ----
                    Flow {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(6)
                      // Shown on the row the cursor is on, not only an
                      // expanded one: otherwise nothing on screen says these
                      // actions exist until you already know to press a key.
                      visible: rowColumn.isExpanded || root.cursor === rowColumn.index
                      spacing: Style.space(6)

                      Repeater {
                        model: {
                          var acts = [
                            { id: "pin", label: (rowColumn.modelData.pinned ? "󰐃 Unpin" : "󰐃 Pin") + "  Ctrl+P" },
                            { id: "note", label: (rowColumn.modelData.note ? "󰏫 Edit note" : "󰏫 Add note") + "  Ctrl+N" },
                            { id: "focus", label: "󰁔 Open app  Enter" },
                            { id: "delete", label: "󰩹 Delete  Ctrl+D" }
                          ]
                          for (var i = 0; i < root.groups.length; i++) {
                            var name = root.groups[i].name
                            var inGroup = (rowColumn.modelData.groups || []).indexOf(name) >= 0
                            acts.push({
                              id: (inGroup ? "ungroup:" : "group:") + name,
                              label: (inGroup ? "󰓼 " : "󰓹 ") + name
                            })
                          }
                          acts.push({ id: "newgroup", label: "󰐕 New group" })
                          return acts
                        }

                        delegate: Rectangle {
                          required property var modelData
                          height: Style.space(24)
                          width: actionLabel.implicitWidth + Style.space(16)
                          radius: Style.spacing.labelGap
                          color: actionMouse.containsMouse
                            ? Color.menu.selectedBackground
                            : "transparent"
                          border.width: 1
                          border.color: String(modelData.id) === "delete"
                            ? Color.urgent
                            : Color.muted

                          Text {
                            id: actionLabel
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: modelData.label
                            color: String(modelData.id) === "delete"
                              ? Color.urgent
                              : Color.menu.text
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            id: actionMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              var id = String(modelData.id)
                              var entry = rowColumn.modelData
                              if (id === "pin") root.togglePin(entry)
                              else if (id === "note") root.editingNote = entry.stem
                              else if (id === "focus") root.focusApp(entry)
                              else if (id === "delete") root.removeEntry(entry)
                              else if (id === "newgroup") root.newGroupFor = entry.stem
                              else if (id.indexOf("ungroup:") === 0)
                                root.removeFromGroup(entry, id.substring(8))
                              else if (id.indexOf("group:") === 0)
                                root.addToGroup(entry, id.substring(6))
                            }
                          }
                        }
                      }
                    }

                    // ---- new group name ----
                    Rectangle {
                      Layout.fillWidth: true
                      Layout.topMargin: Style.space(4)
                      visible: root.newGroupFor === rowColumn.modelData.stem
                      height: Style.space(30)
                      radius: Style.spacing.labelGap
                      color: Color.menu.selectedBackground
                      border.width: 1
                      border.color: Color.accent

                      TextInput {
                        id: groupInput
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        verticalAlignment: TextInput.AlignVCenter
                        color: Color.menu.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        selectByMouse: true
                        clip: true
                        onVisibleChanged: { if (visible) { text = ""; forceActiveFocus() } }
                        onAccepted: {
                          root.addToGroup(rowColumn.modelData, text.trim())
                          root.newGroupFor = ""
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------------------------------------------------- footer

          // The shortcut bar. Drawn as keycaps rather than a sentence of
          // "Ctrl+P pin · Ctrl+N note ·" because that run of punctuation at
          // caption size in the muted colour is the thing nobody reads: the
          // key needs to look like a key, and sit at normal text contrast.
          Flow {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(2)
            spacing: Style.space(10)

            Repeater {
              model: [
                { keys: ["↑", "↓"], label: "move" },
                { keys: ["Enter"], label: "open app" },
                { keys: ["⇧", "Enter"], label: "expand" },
                { keys: ["Ctrl", "P"], label: "pin" },
                { keys: ["Ctrl", "N"], label: "note" },
                { keys: ["Ctrl", "G"], label: "group" },
                { keys: ["Ctrl", "D"], label: "delete" },
                { keys: ["Tab"], label: "by app" },
                { keys: ["Esc"], label: "back" }
              ]

              delegate: Row {
                required property var modelData
                spacing: Style.space(4)

                Repeater {
                  model: parent.modelData.keys
                  delegate: Rectangle {
                    required property string modelData
                    width: Math.max(capText.implicitWidth + Style.space(10), Style.space(20))
                    height: Style.space(18)
                    radius: Style.space(3)
                    color: Color.menu.selectedBackground
                    border.width: 1
                    border.color: Color.menu.border

                    Text {
                      id: capText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: modelData
                      color: Color.menu.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: parent.modelData.label
                  color: Color.menu.text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  // Stem whose "new group" field is open, "" when none is.
  property string newGroupFor: ""
}

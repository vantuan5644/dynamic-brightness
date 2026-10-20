import QtQuick
import Quickshell.Hyprland
import Quickshell.Io

// Keeps wluma's config pointed at the right connectors. Settings are stored per
// monitor description, but wluma only honours entries keyed by connector name
// (DP-1), and connectors get renumbered when a monitor is re-enabled or
// re-plugged. So regenerate on every monitor add/remove, and once at startup in
// case the last session ended on a different layout. `apply` is a no-op when the
// generated config is unchanged, so spurious events cost one CLI run.
Item {
  id: root

  property var manifest: null

  readonly property string cli: decodeURIComponent(
    Qt.resolvedUrl("bin/dynamic-brightness").toString().replace(/^file:\/\//, ""))
  property bool applyQueued: false

  function apply() { applyDebounce.restart() }

  function runApply() {
    if (applyProc.running) { root.applyQueued = true; return }
    root.applyQueued = false
    applyProc.running = true
  }

  // Hotplug arrives as a burst (removed, added, config reload); wait for it
  // to settle so connector names are final before mapping them.
  Timer {
    id: applyDebounce
    interval: 1500
    onTriggered: root.runApply()
  }

  Process {
    id: applyProc
    command: [root.cli, "apply"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") console.warn("dynamic-brightness: " + msg)
      }
    }
    onExited: if (root.applyQueued) root.runApply()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event && event.name ? String(event.name) : ""
      if (name.indexOf("monitoradded") === 0 || name.indexOf("monitorremoved") === 0) root.apply()
    }
  }

  Component.onCompleted: apply()
}

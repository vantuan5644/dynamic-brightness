import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button + popup: one row per monitor with an on/off switch and, while on,
// a Dynamic slider for how hard bright content is dimmed. All state lives in
// bin/dynamic-brightness (settings file + wluma config); this only reads its
// `status` JSON and sends it `set` commands.
Panel {
  id: root
  moduleName: "vantuan5644.dynamic-brightness"
  ipcTarget: "vantuan5644.dynamic-brightness"

  readonly property string cli: decodeURIComponent(
    Qt.resolvedUrl("bin/dynamic-brightness").toString().replace(/^file:\/\//, ""))

  property var status: ({ wluma: { installed: true, running: false, ready: false }, maxStrength: 90, monitors: [] })
  property bool loaded: false
  property bool cursorActive: false
  property int cursorIndex: 0

  // The Repeater's model. Only monitor keys, and only reassigned when the set
  // of monitors changes: handing it the full status array would destroy and
  // rebuild every row on each 2 s poll (luma changes constantly), which drops
  // a slider drag in progress along with its release.
  property var rowKeys: []

  // Changes not yet handed to the CLI, merged per monitor:
  // { connector: { enabled: bool?, strength: int? } }. Each set restarts wluma,
  // so a burst of clicks on one monitor collapses into one command, and clicks
  // on different monitors queue instead of overwriting each other.
  property var pending: ({})
  property int pendingCount: 0
  // Bumped on every queued change; a status read that started before the
  // newest change is stale and is thrown away.
  property int changeGen: 0
  property int statusGen: 0

  readonly property var monitors: status.monitors || []
  readonly property int enabledCount: monitors.filter(function(m) { return m.enabled }).length
  readonly property bool wlumaInstalled: !!(status.wluma && status.wluma.installed)
  readonly property bool wlumaRunning: !!(status.wluma && status.wluma.running)
  readonly property bool wlumaReady: !!(status.wluma && status.wluma.ready)
  readonly property bool busy: setProc.running || pendingCount > 0 || strengthDebounce.running

  function monitorByKey(key) {
    for (var i = 0; i < monitors.length; i++) if (monitors[i].key === key) return monitors[i]
    return null
  }

  // Flat keyboard-cursor list: each monitor's switch, plus its slider when on.
  readonly property var cursorItems: {
    var items = []
    for (var i = 0; i < rowKeys.length; i++) {
      var m = monitorByKey(rowKeys[i])
      items.push({ key: rowKeys[i], kind: "toggle" })
      if (m && m.enabled) items.push({ key: rowKeys[i], kind: "slider" })
    }
    return items
  }

  function hasCursorOn(key, kind) {
    var item = cursorItems[cursorIndex]
    return cursorActive && !!item && item.key === key && item.kind === kind
  }

  function cursorTo(key, kind) {
    cursorActive = true
    for (var i = 0; i < cursorItems.length; i++)
      if (cursorItems[i].key === key && cursorItems[i].kind === kind) { cursorIndex = i; return }
  }

  function moveCursor(delta) {
    if (cursorItems.length === 0) return
    cursorIndex = Math.max(0, Math.min(cursorItems.length - 1, cursorIndex + delta))
  }

  function activateCursor() {
    var item = cursorItems[cursorIndex]
    if (item && item.kind === "toggle") toggleMonitor(item.key)
  }

  function nudgeStrength(delta) {
    var item = cursorItems[cursorIndex]
    if (!item || item.kind !== "slider") return
    var m = monitorByKey(item.key)
    if (m) setStrength(item.key, m.strength + delta * 5)
  }

  function applyStatus(next) {
    status = next
    loaded = true
    var keys = (next.monitors || []).map(function(m) { return m.key })
    if (JSON.stringify(keys) !== JSON.stringify(rowKeys)) rowKeys = keys
  }

  function refresh() {
    if (statusProc.running) return
    statusGen = changeGen
    statusProc.running = true
  }

  // Optimistic: show the change now; the status read after the CLI finishes
  // confirms it.
  function patchMonitor(key, patch) {
    var next = JSON.parse(JSON.stringify(status))
    for (var i = 0; i < next.monitors.length; i++)
      if (next.monitors[i].key === key) Object.assign(next.monitors[i], patch)
    status = next
  }

  function toggleMonitor(key) {
    var m = monitorByKey(key)
    if (!m) return
    var turnOn = !m.enabled
    patchMonitor(key, { enabled: turnOn })
    queue(m.connector, { enabled: turnOn })
  }

  function setStrength(key, value) {
    var m = monitorByKey(key)
    if (!m) return
    var v = Math.max(0, Math.min(status.maxStrength || 90, Math.round(value / 5) * 5))
    if (v === m.strength) return
    patchMonitor(key, { strength: v })
    // Every committed strength restarts wluma (a few seconds of DDC probing),
    // and a scroll wheel commits once per notch: wait for input to settle.
    queue(m.connector, { strength: v }, true)
  }

  function queue(connector, patch, debounce) {
    var next = Object.assign({}, pending)
    next[connector] = Object.assign({}, next[connector] || {}, patch)
    pending = next
    pendingCount = Object.keys(next).length
    changeGen++
    if (debounce) strengthDebounce.restart()
    else if (!strengthDebounce.running) flush()
  }

  function flush() {
    if (setProc.running) return
    var connectors = Object.keys(pending)
    if (connectors.length === 0) return
    var connector = connectors[0]
    var change = pending[connector]
    var next = Object.assign({}, pending)
    delete next[connector]
    pending = next
    pendingCount = connectors.length - 1

    var args = [root.cli, "set", connector]
    if (change.enabled !== undefined) args.push(change.enabled ? "on" : "off")
    if (change.strength !== undefined) args.push("strength=" + change.strength)
    setProc.command = args
    setProc.running = true
  }

  function monitorCaption(m) {
    var parts = [m.position ? m.connector + " (" + m.position + ")" : m.connector]
    if (!m.active) parts.push("off")
    else if (m.enabled && m.luma !== null && m.luma !== undefined)
      parts.push("content " + m.luma + "%", "brightness " + m.brightness + "%")
    else if (m.enabled) parts.push(root.wlumaRunning ? "wluma starting" : "wluma not running")
    else parts.push(m.mode)
    return parts.join(" · ")
  }

  readonly property string heroCaption: {
    if (!wlumaInstalled) return "WLUMA NOT INSTALLED"
    if (enabledCount === 0) return "OFF"
    if (busy) return "APPLYING…"
    if (!wlumaRunning) return "WLUMA NOT RUNNING"
    if (!wlumaReady) return "APPLYING…"
    return enabledCount + " OF " + monitors.length + " ADAPTIVE"
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIndex = 0
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    id: strengthDebounce
    interval: 700
    onTriggered: root.flush()
  }

  Process {
    id: statusProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The UI is already ahead of anything status can report while a
        // change is queued or running, and a read that started before the
        // newest change knows nothing about it.
        if (root.busy) return
        if (root.statusGen !== root.changeGen) { Qt.callLater(root.refresh); return }
        try { root.applyStatus(JSON.parse(text)) } catch (e) {}
      }
    }
  }

  Process {
    id: setProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") console.warn("dynamic-brightness: " + msg)
      }
    }
    onExited: {
      if (root.pendingCount > 0 && !strengthDebounce.running) root.flush()
      else root.refresh()
    }
  }

  // Live luma/brightness readout while the popup is open; the bar icon itself
  // only needs to know whether anything is on, so a slow poll covers it.
  Timer { interval: 2000; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 60000; running: !root.opened; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃡"
    opacity: root.enabledCount > 0 ? 1 : 0.55
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.nudgeStrength(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰃡"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Dynamic brightness"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.heroCaption
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          Text {
            visible: root.loaded && !root.wlumaInstalled
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "This plugin drives wluma, which is not installed. Run: yay -S wluma"
            color: root.bar.foreground
            opacity: 0.8
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- One block per monitor ----------
          Repeater {
            model: root.rowKeys

            Column {
              id: monitorBlock
              required property var modelData
              readonly property string key: modelData
              // Live fields come from status through this binding, so a poll
              // updates the row in place instead of recreating it.
              readonly property var mon: root.monitorByKey(key) || ({})
              width: panelColumn.width
              spacing: Style.space(6)

              PanelSeparator { foreground: root.bar.foreground }

              Toggle {
                width: parent.width
                label: monitorBlock.mon.label || ""
                description: monitorBlock.mon.connector ? root.monitorCaption(monitorBlock.mon) : ""
                checked: monitorBlock.mon.enabled === true
                hasCursor: root.hasCursorOn(monitorBlock.key, "toggle")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.toggleMonitor(monitorBlock.key)
                onHovered: function(h) { if (h) root.cursorTo(monitorBlock.key, "toggle") }
              }

              Item {
                visible: monitorBlock.mon.enabled === true
                width: parent.width
                implicitHeight: Math.max(dynamicHeader.implicitHeight, dynamicValue.implicitHeight)

                PanelSectionHeader {
                  id: dynamicHeader
                  text: "DYNAMIC"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: dynamicValue
                  // What the slider means right now, not just in theory: on a
                  // dark screen even a high strength dims very little.
                  readonly property int strength: Math.round(slider.dragging ? slider.liveValue : (monitorBlock.mon.strength || 0))
                  readonly property var luma: monitorBlock.mon.luma
                  textFormat: Text.PlainText
                  text: "−" + strength + "% on white"
                    + (luma === null || luma === undefined ? "" : " · now −" + Math.round(strength * luma / 100) + "%")
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                visible: monitorBlock.mon.enabled === true
                width: parent.width
                height: slider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.hasCursorOn(monitorBlock.key, "slider")
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: slider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: root.status.maxStrength || 90
                  step: 5
                  integer: true
                  tickCount: Math.round(maximum / 10) + 1
                  value: monitorBlock.mon.strength || 0
                  onReleased: function(v) { root.setStrength(monitorBlock.key, v) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) root.cursorTo(monitorBlock.key, "slider")
                }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Set brightness as usual for dark content; Dynamic is how much is taken off on a fully white screen."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}

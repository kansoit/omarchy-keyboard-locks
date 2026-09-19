import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "CapsIndicatorModel.js" as CapsIndicatorModel

// A single dot that lights up while Caps Lock is on. Reads the Lock modifier
// of the keyboard being typed on, refreshed by a self-registered Caps_Lock
// bind (see CapsIndicatorModel.js) and a light standby poll as a fallback.
BarWidget {
  id: root
  moduleName: "mero.caps-indicator"

  // Injected by the bar from the widget entry, shaped by manifest barWidget.schema.
  property var settings: ({})

  // The Lock modifier of the keyboard the dot reads.
  property bool capsLock: false

  // Which keyboard the seat is actively typing on. Updated either by an
  // activelayout event (layout switch) or by detecting which keyboard toggled
  // its capsLock between two successive polls — the board that just changed is
  // the one the user is pressing. Caps Lock is per-keyboard, so the dot must
  // read the right device when there is more than one on the seat.
  property string typedKeyboardName: ""

  // Previous caps state per keyboard name, used to detect which keyboard just
  // toggled between successive 500 ms standby polls.
  property var _prevCapsState: ({})

  // ---- Settings editing. Left-clicking the dot opens a small editor for the
  //      schema settings; changes are written back to shell.json the same way
  //      the built-in widgets do (updateEntryInline), applied locally first so
  //      the dot responds on the click itself.
  function mergedSettings(changes) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var change in changes) entry[change] = changes[change]
    return entry
  }

  function commitSettings(changes) {
    var entry = root.mergedSettings(changes)
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Applies settings to the live widget only, without touching shell.json.
  // Used while the color field is being edited: a per-keystroke commit round-
  // trips through the config reload and re-asserts the bound field text mid-
  // edit, which fights freeform typing.
  function commitSettingsLocal(changes) {
    root.settings = root.mergedSettings(changes)
  }

  function resetSettings() {
    root.commitSettings({ dotColor: "auto", dotSize: 6, hideWhenOff: false, dimOpacity: 35 })
  }

  // A widget slot routes clicks to the mounted item when no registered click
  // target covers the point; implementing triggerPress turns the whole dot slot
  // into a button, same contract the built-in widgets use.
  function triggerPress(button) {
    if (button === Qt.LeftButton) settingsCard.open = !settingsCard.open
  }

  // Render options, every one of which the schema gives a default. These read
  // root.settings directly (not through the setting() helper) because the
  // binding engine only tracks property dependencies it can see; a JavaScript
  // function call is opaque, so the dot would not update on change.
  readonly property real dotDiameter: {
    var d = root.settings ? Number(root.settings.dotSize) : NaN
    return isNaN(d) || d <= 0 ? 6 : Math.min(d, 24)
  }
  readonly property color onColor: {
    var c = root.settings && root.settings.dotColor !== undefined && root.settings.dotColor !== null
      ? String(root.settings.dotColor).trim() : ""
    return c && c !== "auto" ? c : (root.bar ? root.bar.urgent : Color.urgent)
  }
  readonly property color offColor: root.bar ? root.bar.barForeground : Color.foreground
  readonly property real offOpacity: {
    if (root.hideWhenOffValue) return 0
    return root.dimOpacityValue / 100
  }

  // Editable equivalents the settings card binds against; these clamp the raw
  // entry values so a slider or swatch always reflects a valid state.
  readonly property string dotColorValue: {
    var c = root.settings ? root.settings.dotColor : undefined
    return c === undefined || c === null ? "auto" : String(c)
  }
  readonly property bool hideWhenOffValue: !!(root.settings && root.settings.hideWhenOff)
  readonly property int dotDiameterValue: Math.round(root.dotDiameter)
  readonly property int dimOpacityValue: {
    var o = root.settings ? Number(root.settings.dimOpacity) : NaN
    return Math.round(isNaN(o) ? 35 : Math.max(0, Math.min(100, o)))
  }

  // Hyprland reports more than keyboards as keyboards; buttons and the virtual
  // keyboard fcitx5 binds to inject never carry a Lock modifier worth reading.
  function typedKeyboards(list) {
    return list.filter(function (k) {
      return !/^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/.test(String(k.name || ""))
    })
  }

  // The seat also lists devices that are not keyboards (radio controls, hotkey
  // arrays, HID event sinks), and they never receive key events, so reading the
  // Lock modifier from one would keep the dot stuck. Prefer the keyboard the seat
  // is actively typing on; if one is not yet known, prefer a device whose name
  // says keyboard when one is present.
  function capsKeyboard(typed) {
    // activelayout names the keyboard being typed on, settling a seat with two
    // keyboards outright.
    var named = typed.find(function (k) { return k.name === root.typedKeyboardName })
    if (named) return named

    // When the keyboard has not been identified yet but exactly one real
    // keyboard reports capsLock on, use it directly — it is almost certainly
    // the one the user is pressing.
    if (!root.typedKeyboardName) {
      var capsOnOnly = null
      var capsCount = 0
      for (var i = 0; i < typed.length; i++) {
        var k = typed[i]
        if (!k || !k.name || !/keyboard/i.test(String(k.name || ""))) continue
        if (k.capsLock === true) { capsCount++; capsOnOnly = k }
      }
      if (capsCount === 1 && capsOnOnly) return capsOnOnly
    }

    // The fcitx5 virtual keyboard can hold the main flag without ever being typed
    // on, but a real keyboard marked main is a strong fallback.
    var main = typed.find(function (k) {
      return k.main === true && !/hl-virtual-keyboard/.test(String(k.name || ""))
    })
    if (main) return main

    var kb = typed.find(function (k) {
      return /keyboard/i.test(String(k.name || ""))
    })
    return kb || typed[0] || null
  }

  // A query already in flight was started before this event, so it may read the
  // state the press just changed. Remember the request and re-run once it lands
  // rather than dropping it.
  property bool refreshPending: false

  function refresh() {
    if (queryProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    queryProc.running = true
  }

  // Caps lock raises no Hyprland event at all: the bind that registered
  // refresh() fires on every Caps_Lock press, but xkb releases the lock on key
  // up while a bind only runs on the press. Re-read a few times at short
  // intervals after the press to catch the release, so the dot goes out as the
  // lock does instead of waiting for the standby poll.
  function pressRefresh() {
    settleCurrent = 0
    settleTimer.start()
    refresh()
  }

  property int settleCurrent: 0
  readonly property int settleTicks: 5

  Timer {
    id: settleTimer
    interval: 100
    repeat: true
    onTriggered: {
      root.refresh()
      root.settleCurrent++
      if (root.settleCurrent >= root.settleTicks) stop()
    }
  }

  // The self-registered bind, added at startup and re-added on config reload:
  // the same non-consuming Caps_Lock bind a manual setup would put in
  // bindings.lua, pointed at this widget's own IPC handler. See
  // CapsIndicatorModel.js for how instances share one registration.
  readonly property string bindDescription: String(root.moduleName || "") + " refresh"
  property string bindCode: ""

  function bindPresent(json) {
    try {
      const binds = JSON.parse(String(json || "[]"))
      if (!Array.isArray(binds)) return false
      return binds.some(function (b) {
        return String(b.key || "") === "Caps_Lock" && String(b.description || "") === root.bindDescription
      })
    } catch (e) {
      return false
    }
  }

  function addBind() {
    root.bindCode = 'o.bind("Caps_Lock", "' + root.bindDescription + '", "omarchy-shell -q ' + root.moduleName + ' refresh", { locked = true, non_consuming = true, ignore_mods = true })'
    bindEvalProc.running = true
  }

  function ensureBindAdded() {
    if (!CapsIndicatorModel.claimRegistration()) return
    bindCheckProc.running = true
  }

  IpcHandler {
    target: root.moduleName
    function refresh(): void { root.pressRefresh() }
    function toggleCard(): void { settingsCard.open = !settingsCard.open }
  }

  Component.onCompleted: {
    refresh()
    ensureBindAdded()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      // A switch always names the keyboard being typed on, so the dot knows
      // which device to read when the seat holds more than one.
      if (name === "activelayout") {
        const named = CapsIndicatorModel.eventKeyboardName(event)
        if (named) root.typedKeyboardName = named
      }
      // A reload wipes runtime binds, so re-assert the refresh bind, and re-read
      // the keyboard just in case the reload reset xkb state.
      if (name === "configreloaded") {
        CapsIndicatorModel.invalidate()
        root.ensureBindAdded()
        root.refresh()
      }
    }
  }

  Process {
    id: queryProc
    command: ["hyprctl", "-j", "devices"]
    onRunningChanged: {
      if (running) {
        stallTimer.restart()
        return
      }
      stallTimer.stop()
      if (root.refreshPending) root.refresh()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let listed
        try {
          listed = JSON.parse(text || "{}").keyboards
        } catch (e) {
          return
        }
        if (!Array.isArray(listed)) return

        const typed = root.typedKeyboards(listed)

        // Detect which keyboard just toggled its caps lock between polls.
        // The board that changed is the one the user is actually pressing,
        // so use it as the authoritative source from now on.
        var changed = null
        var prev = root._prevCapsState || {}
        for (var i = 0; i < typed.length; i++) {
          var k = typed[i]
          if (!k || !k.name) continue
          var now = k.capsLock === true
          var before = prev[k.name]
          if (before !== undefined && before !== now) { changed = k; break }
        }

        // Build the new snapshot of per-keyboard caps states for the next poll.
        var next = {}
        for (var j = 0; j < typed.length; j++) {
          var kb2 = typed[j]
          if (kb2 && kb2.name) next[kb2.name] = kb2.capsLock === true
        }
        root._prevCapsState = next

        // If a real keyboard toggled, that's the one being typed on.
        if (changed && !/hl-virtual-keyboard/.test(String(changed.name || "")))
          root.typedKeyboardName = changed.name

        const kb = root.capsKeyboard(typed)
        if (!kb) return
        root.capsLock = kb.capsLock === true
      }
    }
  }

  Process {
    id: bindCheckProc
    command: ["hyprctl", "-j", "binds"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.bindPresent(text) ? undefined : root.addBind()
    }
  }

  Process {
    id: bindEvalProc
    command: ["hyprctl", "eval", root.bindCode]
    stdout: StdioCollector {
      waitForEnd: true
    }
  }

  // A query that never returns would freeze the dot until the shell restarts,
  // since a running Process can't be re-run. Give up on one that overstays so
  // the next refresh gets through, and ask again.
  Timer {
    id: stallTimer
    interval: 5000
    onTriggered: {
      queryProc.running = false
      root.refresh()
    }
  }

  // The Lock modifier cannot be learned from a Hyprland event, and the bind
  // only fires on press, so a light poll is the safety net that catches state
  // changes the bind missed (it also covers systems where the eval bind fails).
  Timer {
    id: standbyTimer
    interval: 500
    running: root.visible
    repeat: true
    onTriggered: root.refresh()
  }

  implicitWidth: root.dotDiameter + 12
  implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  Item {
    id: dotSlot
    width: root.dotDiameter + 12
    height: root.implicitHeight
    anchors.centerIn: parent

    Rectangle {
      id: dot
      width: root.dotDiameter
      height: root.dotDiameter
      radius: width / 2
      anchors.centerIn: dotSlot
      color: root.capsLock ? root.onColor : root.offColor
      opacity: root.capsLock ? 1 : root.offOpacity

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Behavior on color {
        ColorAnimation { duration: 140 }
      }
    }
  }

  // ---- Settings card. Anchored to the dot, opened by the click above; clicks
  //      outside the card dismiss it (PopupCard's focus grab).
  PopupCard {
    id: settingsCard
    bar: root.bar
    anchorItem: dotSlot
    contentWidth: Style.space(320)
    contentHeight: settingsList.implicitHeight + settingsCard.verticalContentInset

    // The bar owns the keyboard (focusable: false), so popups anchored to it
    // can't get key events without asking the layer shell. OnDemand grabs the
    // keyboard when the card is clicked, letting the color field accept typing.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    ColumnLayout {
      id: settingsList
      width: settingsCard.contentWidth - settingsCard.padding * 2
        - Border.left(settingsCard.borderSpec) - Border.right(settingsCard.borderSpec)
      spacing: Style.spacing.controlGap

      RowLayout {
        Layout.fillWidth: true

        Text {
          text: "Caps indicator"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.5
        }

        Item { Layout.fillWidth: true }

        Button {
          text: "Reset"
          fontSize: Style.font.caption
          tooltipText: "Restore all default settings"
          onClicked: root.resetSettings()
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.controlGap

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.lg

          Text {
            Layout.minimumWidth: Style.space(108)
            text: "Dot color"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          RowLayout {
            id: swatchRow
            spacing: Style.spacing.sm

            Repeater {
              model: [
                { value: "auto", color: root.bar ? root.bar.urgent : Color.urgent },
                { value: "#ef4444", color: "#ef4444" },
                { value: "#f59e0b", color: "#f59e0b" },
                { value: "#22c55e", color: "#22c55e" },
                { value: "#3b82f6", color: "#3b82f6" },
                { value: "#a855f7", color: "#a855f7" },
                { value: "#ec4899", color: "#ec4899" }
              ]

              Rectangle {
                required property var modelData
                width: Style.space(20)
                height: Style.space(20)
                radius: width / 2
                color: modelData.color
                border.width: 1
                border.color: Qt.color("black")
                opacity: root.dotColorValue === modelData.value ? 1 : 0.55
                scale: root.dotColorValue === modelData.value ? 1.15 : 1

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: "transparent"
                  border.width: 2
                  border.color: root.dotColorValue === modelData.value ? Color.accent : "transparent"
                  visible: root.dotColorValue === modelData.value
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.commitSettings({ dotColor: modelData.value })
                  hoverEnabled: true
                }
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          Rectangle {
            Layout.preferredWidth: Style.space(20)
            Layout.preferredHeight: Style.space(20)
            radius: width / 2
            border.width: 1
            border.color: Qt.color("#55000000")
            color: root.dotColorValue === "auto" ? (root.bar ? root.bar.urgent : Color.urgent) : root.dotColorValue
          }

          TextField {
            id: colorField
            Layout.fillWidth: true
            text: root.dotColorValue
            placeholderText: "auto or #rrggbb"
            horizontalAlignment: Text.AlignHCenter
            onTextChanged: {
              if (activeFocus && text !== root.dotColorValue)
                root.commitSettingsLocal({ dotColor: text })
            }
            onEditingFinished: root.commitSettings({ dotColor: text.trim() })
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.lg

        Text {
          Layout.minimumWidth: Style.space(108)
          text: "Dot size"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          Layout.preferredWidth: Style.space(28)
          text: String(root.dotDiameterValue)
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
        }

        PanelSlider {
          id: sizeSlider
          Layout.fillWidth: true
          bar: root.bar
          minimum: 2
          maximum: 24
          step: 1
          integer: true
          value: root.dotDiameterValue
          onMoved: function(v) { root.commitSettings({ dotSize: Math.round(v) }) }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.lg

        Text {
          Layout.minimumWidth: Style.space(108)
          text: "Dim at rest (%)"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          Layout.preferredWidth: Style.space(28)
          text: String(root.dimOpacityValue)
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
        }

        PanelSlider {
          id: dimSlider
          Layout.fillWidth: true
          bar: root.bar
          minimum: 0
          maximum: 100
          step: 1
          integer: true
          value: root.dimOpacityValue
          onMoved: function(v) { root.commitSettings({ dimOpacity: Math.round(v) }) }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.lg

        Text {
          Layout.minimumWidth: Style.space(108)
          text: "Hide when off"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Item { Layout.fillWidth: true }

        ToggleSwitch {
          checked: root.hideWhenOffValue
          onToggled: root.commitSettings({ hideWhenOff: !root.hideWhenOffValue })
        }
      }
    }

    // Give the color field keyboard focus as soon as the card opens.
    Connections {
      target: settingsCard
      function onOpenChanged() {
        if (settingsCard.open)
          Qt.callLater(() => colorField.forceActiveFocus())
      }
    }
  }
}
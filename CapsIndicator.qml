import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "CapsIndicatorModel.js" as CapsIndicatorModel

// Letters that light up while Caps Lock or Num Lock is on. Lock state is
// aggregated across real keyboards, so one locked keyboard is enough to show
// the corresponding indicator. Self-registered lock binds provide immediate
// updates; a slower standby poll is the safety net.
BarWidget {
  id: root
  moduleName: "kansoit.keyboard-locks"

  // Injected by the bar from the widget entry, shaped by manifest barWidget.schema.
  property var settings: ({})

  // Aggregated Lock modifiers across real keyboards on the seat.
  property bool capsLock: false
  property bool numLock: false

  // Which keyboard the seat is actively typing on. Updated either by an
  // activelayout event (layout switch) or by detecting which keyboard toggled
  // its capsLock between successive reads — the board that just changed is
  // the one the user is pressing. Caps Lock is per-keyboard, so the dot must
  // read the right device when there is more than one on the seat.
  property string typedKeyboardName: ""

  // Previous lock state per keyboard name, used to identify which keyboard just
  // toggled between successive standby reads.
  property var _prevLockState: ({})
  property var _lastTypedKeyboards: []
  property int _refreshCount: 0

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
    root.commitSettings({ capsColor: "auto", numColor: "auto" })
  }

  // A widget slot routes clicks to the mounted item when no registered click
  // target covers the point; implementing triggerPress turns the whole dot slot
  // into a button, same contract the built-in widgets use.
  function triggerPress(button) {
    if (button === Qt.LeftButton) {
      if (settingsCard.open) settingsCard.closeCard()
      else settingsCard.openCard()
    }
  }

  // Render options, every one of which the schema gives a default. These read
  // root.settings directly (not through the setting() helper) because the
  // binding engine only tracks property dependencies it can see; a JavaScript
  // function call is opaque, so the dot would not update on change.
  readonly property color capsOnColor: {
    var c = root.settings && root.settings.capsColor !== undefined && root.settings.capsColor !== null
      ? String(root.settings.capsColor).trim()
      : (root.settings && root.settings.dotColor !== undefined ? String(root.settings.dotColor).trim() : "")
    return c && c !== "auto" ? c : Color.accent
  }
  readonly property color numOnColor: {
    var c = root.settings && root.settings.numColor !== undefined && root.settings.numColor !== null
      ? String(root.settings.numColor).trim()
      : (root.settings && root.settings.dotColor !== undefined ? String(root.settings.dotColor).trim() : "")
    return c && c !== "auto" ? c : Color.accent
  }
  // Inactive letters deliberately use the normal bar foreground at full
  // opacity. Their state is communicated by the selected active color only.
  readonly property color offColor: root.bar ? root.bar.barForeground : Color.foreground

  // Editable equivalents the settings card binds against; these clamp the raw
  // entry values so a slider or swatch always reflects a valid state.
  readonly property string capsColorValue: {
    var c = root.settings && root.settings.capsColor !== undefined
      ? root.settings.capsColor : (root.settings ? root.settings.dotColor : undefined)
    return c === undefined || c === null ? "auto" : String(c)
  }
  readonly property string numColorValue: {
    var c = root.settings && root.settings.numColor !== undefined
      ? root.settings.numColor : (root.settings ? root.settings.dotColor : undefined)
    return c === undefined || c === null ? "auto" : String(c)
  }
  readonly property var colorChoices: ["auto", "#ef4444", "#f59e0b", "#22c55e", "#3b82f6", "#a855f7", "#ec4899"]

  // Hyprland reports more than keyboards as keyboards; buttons and the virtual
  // keyboard fcitx5 binds to inject never carry a Lock modifier worth reading.
  function typedKeyboards(list) {
    return list.filter(CapsIndicatorModel.isRealKeyboard)
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
    root._refreshCount++
    queryProc.running = true
  }

  // The lock bind fires on the key press, but xkb may publish the new modifier
  // state just after that press. Re-read a few times at short intervals to
  // catch the settled state without making the standby poll aggressive.
  function pressRefresh() {
    settleCurrent = 0
    settleTimer.start()
    refresh()
  }

  property int settleCurrent: 0
  readonly property int settleTicks: 8

  Timer {
    id: settleTimer
    // Hyprland may publish the new xkb state just after the key bind fires.
    // Check quickly during that short transition; the standby poll remains
    // deliberately slow when no key was pressed.
    interval: 30
    repeat: true
    onTriggered: {
      root.refresh()
      root.settleCurrent++
      if (root.settleCurrent >= root.settleTicks) stop()
    }
  }

  // The self-registered binds, added at startup and re-added on config reload,
  // point at this widget's own IPC handler. Registration is made idempotent by
  // removing the plugin's lock-key bindings before adding one of each kind.
  readonly property string bindDescription: String(root.moduleName || "") + " refresh"
  property string bindCode: ""

  function addBind() {
    var command = 'omarchy-shell -q ' + root.moduleName + ' refresh'
    var options = '{ locked = true, non_consuming = true, ignore_mods = true }'
    root.bindCode = 'hl.unbind("Caps_Lock"); hl.unbind("Num_Lock"); o.bind("Caps_Lock", "' + root.bindDescription + '", "' + command + '", ' + options + '); o.bind("Num_Lock", "' + root.bindDescription + '", "' + command + '", ' + options + ')'
    bindEvalProc.running = true
  }

  function ensureBindAdded() {
    if (!CapsIndicatorModel.claimRegistration()) return
    root.addBind()
  }

  IpcHandler {
    target: root.moduleName
    // Only one per-monitor instance owns the IPC target. Forward the event to
    // every live copy so secondary bars do not wait for the 2-second fallback
    // poll before showing the new lock state.
    function refresh(): void { root.broadcast("pressRefresh") }
    function status(): string {
      return JSON.stringify({
        visible: root.visible,
        capsLock: root.capsLock,
        numLock: root.numLock,
        typedKeyboardName: root.typedKeyboardName,
        refreshCount: root._refreshCount,
        queryRunning: queryProc.running,
        standbyRunning: standbyTimer.running,
        keyboards: root._lastTypedKeyboards
      })
    }
    function toggleCard(): void {
      if (settingsCard.open) settingsCard.closeCard()
      else settingsCard.openCard()
    }
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
        root._lastTypedKeyboards = typed

        // Detect which keyboard just toggled either lock between polls. Keep
        // the name for the active-layout fallback, but aggregate the displayed
        // state across all real keyboards.
        var changed = null
        var prev = root._prevLockState || {}
        for (var i = 0; i < typed.length; i++) {
          var k = typed[i]
          if (!k || !k.name) continue
          var nowCaps = k.capsLock === true
          var nowNum = k.numLock === true
          var before = prev[k.name]
          if (before !== undefined
              && (before.capsLock !== nowCaps || before.numLock !== nowNum)) {
            changed = k
            break
          }
        }

        // Build the new snapshot of per-keyboard lock states for the next poll.
        var next = {}
        for (var j = 0; j < typed.length; j++) {
          var kb2 = typed[j]
          if (kb2 && kb2.name) {
            next[kb2.name] = {
              capsLock: kb2.capsLock === true,
              numLock: kb2.numLock === true
            }
          }
        }
        root._prevLockState = next

        // If a real keyboard toggled, that's the one being typed on.
        if (changed && !/hl-virtual-keyboard/.test(String(changed.name || "")))
          root.typedKeyboardName = changed.name

        root.capsLock = CapsIndicatorModel.anyLock(typed, "capsLock")
        root.numLock = CapsIndicatorModel.anyLock(typed, "numLock")
      }
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

  // The bind is the fast path. The slower poll catches missed events, state
  // changes made by another input tool, and systems where the eval bind fails.
  Timer {
    id: standbyTimer
    interval: 2000
    running: root.visible
    repeat: true
    onTriggered: root.refresh()
  }

  implicitWidth: Style.space(34)
  implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  Item {
    id: dotSlot
    width: root.implicitWidth
    height: root.implicitHeight
    anchors.centerIn: parent

    Row {
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        width: Style.space(10)
        height: root.implicitHeight
        text: "C"
        color: root.capsLock ? root.capsOnColor : root.offColor
        opacity: 1
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter

        Behavior on color {
          ColorAnimation { duration: 60 }
        }
      }

      Text {
        width: Style.space(10)
        height: root.implicitHeight
        text: "N"
        color: root.numLock ? root.numOnColor : root.offColor
        opacity: 1
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter

        Behavior on color {
          ColorAnimation { duration: 60 }
        }
      }
    }
  }

  // ---- Settings card. A full-screen overlay panel: a popup window anchored to
  //      the (non-keyboard-focusable) bar can never receive key events, so the
  //      color field couldn't be typed into. Exclusive keyboard focus — the same
  //      trick the reminders flow and KeyboardPanel use — delivers keys here.
  //      Clicking the scrim (or Escape) closes it.
  PanelWindow {
    id: settingsCard
    visible: open
    color: "transparent"
    property bool open: false

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    WlrLayershell.namespace: "kansoit-keyboard-locks-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    function openCard() {
      if (root.bar && typeof root.bar.requestPopout === "function")
        root.bar.requestPopout(settingsCard)
      open = true
      Qt.callLater(function() { capsColorField.forceActiveFocus() })
    }

    function closeCard() {
      open = false
      if (root.bar && typeof root.bar.releasePopout === "function")
        root.bar.releasePopout(settingsCard)
    }

    // The bar closes the previous popup when another one opens.
    function closeForPopoutSwitch() { closeCard() }
    function close() { closeCard() }

    // Click anywhere outside the card to dismiss it.
    MouseArea {
      anchors.fill: parent
      onClicked: settingsCard.closeCard()
    }

    BorderSurface {
      id: card
      width: Style.space(380)
      height: Math.min(settingsList.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       settingsCard.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      // Swallow card clicks so the dismiss MouseArea can't reach them.
      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        id: settingsList
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.controlGap

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: "Lock indicators"
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
              Layout.minimumWidth: Style.space(120)
              text: "Caps Lock color"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            RowLayout {
              id: capsSwatchRow
              spacing: Style.spacing.sm

              Repeater {
                model: root.colorChoices

                Rectangle {
                  required property string modelData
                  width: Style.space(20)
                  height: Style.space(20)
                  radius: width / 2
                  color: modelData === "auto" ? Color.accent : modelData
                  border.width: 1
                  border.color: Qt.color("black")
                  opacity: root.capsColorValue === modelData ? 1 : 0.55
                  scale: root.capsColorValue === modelData ? 1.15 : 1

                  Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: root.capsColorValue === modelData ? Color.accent : "transparent"
                    visible: root.capsColorValue === modelData
                  }

                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.commitSettings({ capsColor: modelData })
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
              color: root.capsColorValue === "auto" ? Color.accent : root.capsColorValue
            }

            TextField {
              id: capsColorField
              Layout.fillWidth: true
              text: root.capsColorValue
              placeholderText: "auto or #rrggbb"
              horizontalAlignment: Text.AlignHCenter
              onTextChanged: {
                if (activeFocus && text !== root.capsColorValue)
                  root.commitSettingsLocal({ capsColor: text })
              }
              onEditingFinished: root.commitSettings({ capsColor: text.trim() })

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  settingsCard.closeCard()
                  event.accepted = true
                }
              }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.lg

            Text {
              Layout.minimumWidth: Style.space(120)
              text: "Num Lock color"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            RowLayout {
              spacing: Style.spacing.sm

              Repeater {
                model: root.colorChoices

                Rectangle {
                  required property string modelData
                  width: Style.space(20)
                  height: Style.space(20)
                  radius: width / 2
                  color: modelData === "auto" ? Color.accent : modelData
                  border.width: 1
                  border.color: Qt.color("black")
                  opacity: root.numColorValue === modelData ? 1 : 0.55
                  scale: root.numColorValue === modelData ? 1.15 : 1

                  Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: root.numColorValue === modelData ? Color.accent : "transparent"
                    visible: root.numColorValue === modelData
                  }

                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.commitSettings({ numColor: modelData })
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
              color: root.numColorValue === "auto" ? Color.accent : root.numColorValue
            }

            TextField {
              id: numColorField
              Layout.fillWidth: true
              text: root.numColorValue
              placeholderText: "auto or #rrggbb"
              horizontalAlignment: Text.AlignHCenter
              onTextChanged: {
                if (activeFocus && text !== root.numColorValue)
                  root.commitSettingsLocal({ numColor: text })
              }
              onEditingFinished: root.commitSettings({ numColor: text.trim() })

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  settingsCard.closeCard()
                  event.accepted = true
                }
              }
            }
          }
        }

      }
    }
  }
}

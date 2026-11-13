import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Tablet Display bar widget.
//
// A thin front end over bin/omarchy-tablet-display-ctl, which does all the
// work (headless output, sunshine.conf, restarting Sunshine) and reports a
// single JSON state. The panel polls that state and sends commands; it never
// touches Hyprland or Sunshine itself.
//
// The shell creates one copy of this widget per monitor, and extending adds a
// monitor, so nothing here may assume it is the only copy: all state lives in
// the control script's files, not in QML properties.

Panel {
  id: root
  moduleName: "omarchy-tablet-display"
  ipcTarget: "omarchy-tablet-display"

  readonly property string ctl: {
    var url = Qt.resolvedUrl("bin/omarchy-tablet-display-ctl").toString()
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : "omarchy-tablet-display-ctl"
  }

  readonly property var emptyState: ({
    installed: true, running: false, mode: "off", busy: "", output: "", target: "",
    client: null, errors: [], notice: "", monitor: null, monitors: [], host: "", addresses: [],
    defaultResolution: "2560x1600",
    settings: { position: "right", scale: "2", resolution: "auto", refresh: "auto", audio: false, lastClient: null }
  })

  property var state: emptyState
  property string pendingMode: ""   // what we asked for, until the script answers

  readonly property bool working: commandProc.running || state.busy !== ""
  readonly property string mode: state.mode
  readonly property bool live: mode !== "off"
  // Connected right now, from Sunshine's own log: a session left open in
  // Moonlight without quitting still has a client, but nobody is watching.
  readonly property bool streaming: live && state.connected === true
  readonly property bool overUsb: streaming && !!state.link && state.link.via === "usb"
  readonly property var usbLinks: state.usb || []
  readonly property bool usbBlocked: usbLinks.some(function(l) { return l.firewall === "blocked" || l.firewall === "unknown" })
  readonly property var s: state.settings

  function parse(text) {
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") return parsed
    } catch (e) {}
    return root.state
  }

  function run(args) {
    if (commandProc.running) return
    commandProc.command = [root.ctl].concat(args)
    commandProc.running = true
  }

  function setMode(m) {
    if (m === root.mode || root.working) return
    root.pendingMode = m
    run(m === "off" ? ["off"] : [m])
  }

  function setOption(key, value) { run(["set", key, String(value)]) }

  function resLabel(r) {
    return r.replace("x", "×")
  }

  readonly property string statusLine: {
    if (!state.installed) return "Sunshine is not installed"
    if (state.busy === "starting" || (commandProc.running && pendingMode !== "" && pendingMode !== "off"))
      return "Starting Sunshine…"
    if (state.busy === "stopping" || (commandProc.running && pendingMode === "off"))
      return "Turning off…"
    if (mode === "off") return "Off"
    var m = state.monitor
    var where = m ? resLabel(m.width + "x" + m.height) : ""
    if (mode === "mirror") return "Mirroring " + state.target + (where ? " · " + where : "")
    return "Extending " + ({ left: "to the left", right: "to the right", above: "above", below: "below" }[s.position] || "")
      + (where ? " · " + where : "")
  }

  readonly property string detailLine: {
    if (!state.installed || !live) return ""
    if (!state.running) return "Sunshine is not running"
    if (streaming) {
      var via = !state.link ? "" : ({ usb: " over USB", wifi: " over Wi-Fi", tailscale: " over Tailscale", network: " over the network" }[state.link.via] || "")
      return "Moonlight connected" + via
        + (state.client ? " · " + resLabel(state.client.width + "x" + state.client.height) + " @ " + state.client.fps + " fps" : "")
    }
    if (state.client) return "Moonlight disconnected. Reconnect from Moonlight to pick up where you left off."
    if (usbLinks.length > 0) return "Waiting for Moonlight: over USB, connect to " + usbLinks[0].ip
    return "Waiting for Moonlight: connect to " + (state.host || "this PC")
  }

  readonly property string glyph: "󰓶"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.streaming
    dimmed: !root.live
    tooltipText: "Tablet Display · " + root.statusLine + (root.overUsb ? " · over USB" : "")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.setMode(root.live ? "off" : "extend")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(640))

    Item {
      id: body
      width: parent.width
      implicitHeight: column.implicitHeight

      readonly property color dim: Qt.darker(root.bar.foreground, 1.4)

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.md

        PanelHero {
          id: hero
          width: parent.width
          title: "Tablet Display"
          meta: root.statusLine
          // A short pill only; PanelHero neither elides nor wraps it.
          detail: root.overUsb ? "Live · USB" : (root.streaming ? "Live" : "")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.glyph
              color: root.streaming ? Color.accent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            Button {
              visible: root.state.installed
              tooltipText: "Sunshine settings"
              iconText: "󰒓"
              iconSize: Style.font.icon
              foreground: hero.foreground
              fontFamily: hero.fontFamily
              onClicked: root.run(["admin"])
            }
          }
        }

        Text {
          width: parent.width
          visible: root.detailLine !== ""
          textFormat: Text.PlainText
          text: root.detailLine
          color: body.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------------------------------------------------- messages
        Item {
          width: parent.width
          visible: root.state.errors.length > 0 || root.state.notice !== ""
          implicitHeight: visible ? Math.max(messages.implicitHeight, dismiss.implicitHeight) : 0

          Column {
            id: messages
            anchors.left: parent.left
            anchors.right: dismiss.left
            anchors.rightMargin: Style.spacing.controlGap
            spacing: Style.spacing.sm

            Repeater {
              model: root.state.errors
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: modelData
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
            Text {
              width: parent.width
              visible: root.state.notice !== ""
              textFormat: Text.PlainText
              text: root.state.notice
              color: body.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Button {
            id: dismiss
            anchors.right: parent.right
            anchors.top: parent.top
            iconText: "󰅖"
            iconSize: Style.font.icon
            tooltipText: "Dismiss"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.run(["clear-errors"])
          }
        }

        Text {
          width: parent.width
          visible: (root.state.hint || "") !== ""
          textFormat: Text.PlainText
          text: root.state.hint || ""
          color: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------------------------------------------------- not installed
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: !root.state.installed

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "This uses Sunshine to stream to Moonlight on your tablet. Omarchy's installer adds it and opens its ports on your LAN and Tailscale (it asks for your password)."
            color: body.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Button {
            text: "Install Sunshine"
            iconText: "󰏔"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.run(["install"])
          }
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground; visible: root.state.installed }

        // ---------------------------------------------------- mode
        PanelSectionHeader {
          visible: root.state.installed
          text: "Mode"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        ButtonGroup {
          visible: root.state.installed
          enabled: !root.working
          width: parent.width
          value: root.working && root.pendingMode !== "" ? root.pendingMode : root.mode
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          options: [
            { value: "off", label: "Off", icon: "󰶐" },
            { value: "extend", label: "Extend", icon: "󰍺", tooltip: "Add the tablet as a new monitor" },
            { value: "mirror", label: "Mirror", icon: "󰍹", tooltip: "Show the focused monitor on the tablet" }
          ]
          onChanged: function(v) { root.setMode(v) }
        }

        Text {
          width: parent.width
          visible: root.state.installed
          textFormat: Text.PlainText
          text: "Extend and Mirror change Sunshine's settings and restart it. Off puts your settings back."
          color: body.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------------------------------------------------- layout (extend)
        Column {
          width: parent.width
          spacing: Style.spacing.md
          visible: root.state.installed && root.mode !== "mirror"

          PanelSectionHeader {
            text: "Position"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }
          ButtonGroup {
            width: parent.width
            enabled: !root.working
            value: root.s.position
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: [
              { value: "left", label: "Left", icon: "󰁍" },
              { value: "right", label: "Right", icon: "󰁔" },
              { value: "above", label: "Above", icon: "󰁝" },
              { value: "below", label: "Below", icon: "󰁅" }
            ]
            onChanged: function(v) { root.setOption("position", v) }
          }

          PanelSectionHeader {
            text: "Scale"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }
          // Only scales that divide common tablet panels into whole logical
          // pixels; Hyprland silently rounds anything else to its own pick.
          ButtonGroup {
            width: parent.width
            enabled: !root.working
            value: String(root.s.scale)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: ["1", "1.25", "1.6", "2"]
            onChanged: function(v) { root.setOption("scale", v) }
          }

        }

        Toggle {
          width: parent.width
          visible: root.state.installed
          enabled: !root.working
          label: "Play sound on the tablet"
          description: root.live ? "Changing this restarts the stream" : ""
          checked: root.s.audio === true
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.setOption("audio", !(root.s.audio === true))
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground; visible: root.state.installed }

        // ---------------------------------------------------- connect help
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: root.state.installed

          // USB tethering: the tablet reaches Sunshine over the cable at this
          // computer's address on the USB link.
          Row {
            width: parent.width
            visible: root.usbLinks.length > 0
            spacing: Style.spacing.sm

            Text {
              id: usbGlyph
              textFormat: Text.PlainText
              text: "󰕓"
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width - usbGlyph.width - parent.spacing
              textFormat: Text.PlainText
              text: root.overUsb
                ? "Streaming over USB"
                : "Tablet connected by USB. In Moonlight, add " + root.usbLinks.map(function(l) { return l.ip }).join(" or ")
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              wrapMode: Text.WordWrap
            }
          }
          Text {
            width: parent.width
            visible: root.usbBlocked
            textFormat: Text.PlainText
            text: root.usbLinks.some(function(l) { return l.firewall === "blocked" })
              ? "The firewall blocks Sunshine on the USB link, so Moonlight can't connect over the cable."
              : "Couldn't read the firewall rules. If Moonlight can't connect over USB, allow Sunshine through the firewall."
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Button {
            visible: root.usbBlocked
            text: "Allow in firewall"
            iconText: "󰒃"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.run(["firewall"])
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "In Moonlight on the tablet, add this PC (it usually appears on its own) and open Desktop. The first time, pair it with the PIN Moonlight shows."
            color: body.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.state.addresses.length > 0
            text: root.state.host + " · " + root.state.addresses.map(function(a) { return a.ip }).join(" · ")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Button {
            text: "Enter pairing PIN"
            iconText: "󰌆"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.run(["pair"])
          }
        }
      }
    }
  }

  // -------------------------------------------------------- processes

  Process {
    id: stateProc
    command: [root.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.state = root.parse(text)
    }
  }

  Timer {
    // Poll quickly while open or while something is changing, lazily otherwise
    // (the bar icon only needs to notice a Moonlight session coming and going).
    interval: root.opened || root.working ? 1000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!stateProc.running) stateProc.running = true
  }

  Process {
    id: commandProc
    onRunningChanged: {
      if (running) return
      root.pendingMode = ""
      if (!stateProc.running) stateProc.running = true
    }
  }
}

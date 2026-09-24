import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Which Claude account the `claude` CLI is signed into, and moving that login
// between accounts. Every decision lives in `bin/omarchy-claude-account`; this
// file only runs it, parses its JSON, and keeps the answer fresh.
//
// The status poll is deliberately cheap and frequent: the switch control is
// disabled while a Claude session is live, and a control that stays greyed out
// for a minute after you quit `claude` reads as broken. Polling only runs
// while the panel is open.
Item {
  id: root
  visible: false

  readonly property string helper: Qt.resolvedUrl("bin/omarchy-claude-account")
    .toString().replace(/^file:\/\//, "")

  // Poll faster while the panel is open so the button un-greys promptly, and
  // keep a slow background beat so the bar's own state is never badly stale.
  property bool panelOpen: false

  property var status: Model.emptyAccountStatus("")
  property bool loading: true
  property bool switching: false
  property string switchingLabel: ""
  property string lastError: ""
  property string lastMessage: ""

  readonly property var accounts: status.accounts || []
  readonly property string activeLabel: status.activeLabel || ""
  readonly property bool available: status.ok === true
  readonly property bool canSwitch: status.canSwitch === true && !switching
  readonly property string blockedReason: status.blockedReason || ""

  signal switched()

  // A label the panel can show next to the control: the registered account
  // name when there is one, the signed-in address when the login has no label
  // yet, and an honest blank when nobody is signed in.
  readonly property string activeDisplayName: {
    if (status.activeLabel !== "") return status.activeLabel
    if (status.activeEmail !== "") return status.activeEmail
    return ""
  }

  function reasonFor(account) {
    return Model.switchBlockedReason(status, account)
  }

  function canSwitchTo(account) {
    return reasonFor(account) === ""
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.panelOpen ? 3000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: [root.helper, "status", "--json"]

    property string buffer: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusProcess.buffer = text
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("ai-agents/accounts", text.trim())
    }

    onExited: function(exitCode) {
      Qt.callLater(function() { root.finishStatus(exitCode) })
    }
  }

  function refresh() {
    if (statusProcess.running || switching) return
    statusProcess.buffer = ""
    statusProcess.running = true
  }

  function finishStatus(exitCode) {
    loading = false
    if (exitCode !== 0) {
      status = Model.emptyAccountStatus(
        exitCode === 127 ? "The account helper is not installed"
                         : "The account helper exited " + exitCode)
      return
    }
    status = Model.parseAccountStatus(statusProcess.buffer)
  }

  // ------------------------------------------------------------------ switch

  Process {
    id: switchProcess
    running: false

    property string buffer: ""
    property string errorBuffer: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: switchProcess.buffer = text
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: switchProcess.errorBuffer = text
    }

    onExited: function(exitCode) {
      Qt.callLater(function() { root.finishSwitch(exitCode) })
    }
  }

  function switchTo(label) {
    if (switching) return
    var target = String(label || "")
    if (target === "" || target === activeLabel) return

    // The poll answer can be a few seconds old, and a session that started in
    // between must not have its credential pulled out from under it. The
    // helper re-checks and refuses on its own; this is just the cheap first
    // gate so the UI does not pretend to start something that will be denied.
    if (!canSwitch) {
      lastError = blockedReason !== "" ? blockedReason : "Switching is unavailable right now"
      return
    }

    lastError = ""
    lastMessage = ""
    switching = true
    switchingLabel = target
    switchProcess.buffer = ""
    switchProcess.errorBuffer = ""
    switchProcess.command = [root.helper, "switch", target, "--json"]
    switchProcess.running = true
  }

  function finishSwitch(exitCode) {
    var parsed = null
    try {
      parsed = JSON.parse(String(switchProcess.buffer || ""))
    } catch (e) {
      parsed = null
    }

    if (exitCode === 0 && parsed && parsed.ok === true) {
      lastMessage = parsed.unchanged === true
        ? switchingLabel + " was already active"
        : "Switched to " + switchingLabel
      lastError = ""
      root.switched()
    } else {
      lastError = (parsed && parsed.error)
        ? String(parsed.error)
        : (String(switchProcess.errorBuffer || "").trim() || "The switch failed")
      lastMessage = ""
    }

    switching = false
    switchingLabel = ""
    // Whatever happened, the truth is now on disk rather than in this reply.
    Qt.callLater(root.refresh)
  }
}

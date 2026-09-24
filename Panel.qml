import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One bar icon and one panel for every AI coding subscription on the machine:
// the token history Omarchy's collectors produce, the pace detail and provider
// coverage ai-usagebar produces, and a switch for which Claude account the CLI
// is signed into.
//
// Layout note, because this panel is read on very different displays: no font
// size, column width or row height is a literal pixel count. Text columns are
// measured with TextMetrics at the live font, everything else comes from
// `Style.space`/`Style.font`, and every label either wraps or elides. A larger
// `[font] base-size` or `[spacing] scale` grows the panel instead of clipping
// it, and long content shortens instead of painting past the edge.
Panel {
  id: root
  moduleName: "cbrompton.ai-agents"
  ipcTarget: "cbrompton.ai-agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property var providers: usage.providers
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    var found = Model.indexOfProvider(providers, selectedProviderId)
    return found >= 0 ? found : 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "resets in" read this instead of Date.now() so the panel
  // keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: provider ? (provider.limits || []) : []
  readonly property var models: modelRows(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: Model.anyAlarming(providers)

  // ------------------------------------------------------------- settings

  // `setting(name, fallback)` comes from the base Panel.
  readonly property bool showValue: Model.booleanSetting(setting("showValue", true), true)
  readonly property bool showProvider: Model.booleanSetting(setting("showProvider", false), false)
  readonly property bool showAll: Model.booleanSetting(setting("showAll", false), false)
  readonly property string barWindow: Model.normalizeBarWindow(setting("barWindow", "auto"))
  readonly property bool accountSwitchEnabled: Model.booleanSetting(setting("accountSwitch", true), true)

  readonly property var barChips: Model.barChips(providers, selectedProviderId, showAll,
                                                 showValue, showProvider, barWindow)

  function alpha(color, opacity) {
    return Qt.rgba(color.r, color.g, color.b, opacity)
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
    accounts.refresh()
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  function launchDashboard() {
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation ai-usagebar-tui")
    root.close()
  }

  // ---------------------------------------------------------------- limits

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ai-usagebar already writes the pace sentence ("52% elapsed, 42pts under"),
  // and it leads with its own countdown. A record-sourced window has no detail
  // line at all, so the countdown is synthesized for it instead -- that way
  // every row ends with a reset, whichever feed it came from.
  function limitDetail(w) {
    if (!w) return ""
    if (String(w.detail || "") !== "") return w.detail
    var remaining = resetMsFor(w)
    return remaining > 0 ? "Resets in " + formatDuration(remaining) : ""
  }

  function severityColor(w) {
    if (!w) return root.foreground
    if (w.severity === "high" || w.percent >= 0.9) return root.urgent
    if (w.severity === "medium" || w.percent >= 0.75) return root.accent
    return root.foreground
  }

  function limitValueText(w) {
    if (!w) return "—"
    // ai-usagebar's own rendering carries units a bare percentage would lose
    // ("0.00 CAD of 0.00 CAD"), so it wins wherever it exists.
    if (String(w.value || "") !== "") return w.value
    return w.percent >= 0 ? Math.round(w.percent * 100) + "%" : "—"
  }

  // ---------------------------------------------------------------- balance

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.statusText || "") !== "") return p.statusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    return today ? "Today" : dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + Model.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never count
    // prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: Model.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + Model.formatTokenCount(row.input)
      + " · out " + Model.formatTokenCount(row.output)
      + " · cache read " + Model.formatTokenCount(row.cacheRead)
      + " · cache write " + Model.formatTokenCount(row.cacheWrite)
  }

  function tooltipText() {
    if (!provider) return "AI usage"
    var window = Model.bindingWindow(provider.limits)
    if (!window) return provider.providerName
    return provider.providerName + " · " + window.title + " "
      + Math.round(window.percent * 100) + "%"
  }

  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    var parts = []
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      parts.push("Merged from " + provider.syncDeviceCount + " device"
                 + (provider.syncDeviceCount === 1 ? "" : "s"))
    if (provider && provider.stale) parts.push("cached reading")
    if (usage.vendorError !== "") parts.push(usage.vendorError)
    return parts.join(" · ")
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing from
  // this panel: assets/<id>.svg if it ships one, the module's bar glyph if it
  // doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5
        && usage.hasLightMark(p.providerId))
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run an agent.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: {
    accounts.panelOpen = opened
    if (opened) {
      cursorActive = false
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      usage.refreshLimits()
      accounts.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Main {
    id: usage
    settings: root.settings
  }

  Accounts {
    id: accounts
    // A switch changes which account the collectors report on, so the numbers
    // on screen are about to be someone else's.
    onSwitched: usage.refreshAll(true)
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
    function account(label: string): string {
      if (label === "") return root.accountsSummary()
      accounts.switchTo(label)
      return "switching to " + label
    }
  }

  function accountsSummary() {
    if (!accounts.available) return "account switching unavailable"
    var lines = []
    for (var i = 0; i < accounts.accounts.length; i++) {
      var entry = accounts.accounts[i]
      lines.push((entry.active ? "* " : "  ") + entry.label)
    }
    return lines.length > 0 ? lines.join("\n") : "no accounts registered"
  }

  // ------------------------------------------------------------------- bar

  // WidgetButton, not BarIconButton: the latter paints its own glyph centred in
  // the slot, which would sit on top of the chips below. Suppressing the label
  // and declaring visual content by hand is how a widget draws its own bar
  // content.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fontSize: Style.font.bodySmall
    active: root.alarming
    tooltipText: root.tooltipText()
    // Horizontal bars carry the chips, so the slot has to be as wide as they
    // are; a vertical bar shows the glyph alone and keeps the default width.
    fixedWidth: root.vertical ? -1 : chipRow.implicitWidth + Style.spaceReal(17)

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (delta !== 0) root.selectProvider(root.providerIndex + (delta < 0 ? 1 : -1))
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(10)
      visible: !root.vertical

      Repeater {
        model: root.barChips

        Row {
          required property var modelData
          spacing: Style.space(4)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: text !== ""
            text: modelData.glyph !== "" ? modelData.glyph : "󱚣"
            color: modelData.alarming && button.useActiveColor ? button.activeColor : button.foreground
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: modelData.label !== ""
            text: modelData.label
            color: modelData.alarming && button.useActiveColor ? button.activeColor : button.foreground
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
          }
        }
      }
    }

    Text {
      visible: root.vertical
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.alarming ? "󰅙" : "󱚣"
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      rotation: button.textRotation
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Both dimensions are requests, not commitments: `fitted*` clamps them to
    // what the screen actually has, which is what keeps the panel usable on a
    // small display or at a large font scale.
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "a" || t === "A") root.cycleAccount()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns
                // the array's identity without changing its content. Restart
                // the fallback walk only when the URLs change: re-pointing
                // source at a URL whose load already failed emits no
                // statusChanged, so an identity-only reset would strand the
                // walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length
                    ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips
                  // the binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: "󱚣"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          //
          // A Flow, not a Row of equal thirds: with ai-usagebar contributing
          // providers, the count is open-ended, and dividing the width by it
          // would squeeze names to nothing. Chips keep their natural size and
          // wrap onto another line instead -- which is also what keeps them
          // legible when the font scale goes up.
          Flow {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                // One chip must never be wider than the panel, however long a
                // provider decides to name itself.
                width: Math.min(implicitWidth, providerSwitch.width)
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.statusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: {
                if (!root.provider) return ""
                var help = String(root.provider.helpText || "")
                return help !== "" ? help : String(root.provider.statusText || "")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Claude account ----------
          PanelSeparator {
            visible: accountSection.visible
            foreground: root.foreground
          }

          Column {
            id: accountSection
            // Only Claude has a login this panel can move, and only when the
            // helper is actually answering.
            visible: root.accountSwitchEnabled && !!root.provider
              && root.provider.supportsAccountSwitch && accounts.available
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "CLAUDE ACCOUNT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Who is signed in right now, and the address behind the label.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: {
                if (accounts.activeDisplayName === "") return "Not signed in"
                var detail = accounts.status.activeEmail
                if (detail !== "" && detail !== accounts.activeDisplayName)
                  return accounts.activeDisplayName + " · " + detail
                return accounts.activeDisplayName
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Flow {
              id: accountRow
              visible: accounts.accounts.length > 0
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: accounts.accounts

                Button {
                  required property var modelData
                  // Every reason a switch cannot happen ends up here, and the
                  // button explains itself rather than just refusing: a live
                  // session, a locked keyring, an account with no stored
                  // credential, or an unlabelled login that would be lost.
                  readonly property string blockedReason: accounts.reasonFor(modelData)
                  readonly property bool switchable: blockedReason === "" && !accounts.switching
                  readonly property bool isSwitching: accounts.switching
                    && accounts.switchingLabel === modelData.label

                  text: isSwitching ? modelData.label + "…" : modelData.label
                  selected: modelData.active
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  width: Math.min(implicitWidth, accountRow.width)

                  // The greying-out the whole feature turns on. `enabled`
                  // stops the click; the opacity is what makes it obvious
                  // before you try.
                  enabled: switchable
                  opacity: switchable || modelData.active ? 1.0 : 0.45
                  tooltipText: blockedReason

                  onClicked: accounts.switchTo(modelData.label)
                }
              }
            }

            // Why the row above is greyed out, stated once rather than only in
            // per-button tooltips -- the tooltip is discoverable, this is not
            // missable.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: {
                if (accounts.switching) return "Switching…"
                if (accounts.lastError !== "") return accounts.lastError
                if (accounts.lastMessage !== "") return accounts.lastMessage
                if (accounts.accounts.length === 0)
                  return "No accounts registered yet. Run `omarchy-claude-account adopt <label>` "
                    + "to name the login you are using, then `add <label>` for the second one."
                if (!accounts.status.keyringAvailable)
                  return accounts.status.keyringMessage
                if (!accounts.canSwitch && accounts.blockedReason !== "")
                  return accounts.blockedReason + " — switching is disabled until it exits."
                if (accounts.status.unmanagedActive)
                  return "The active login has no label. Run `omarchy-claude-account adopt <label>` "
                    + "so it can be switched back to."
                return ""
              }
              color: accounts.lastError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.right: balanceValue.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Tokens by day ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays
              && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Tokens by model ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full --
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  function cycleAccount() {
    if (!accounts.available || accounts.accounts.length < 2 || !accounts.canSwitch) return
    var current = -1
    for (var i = 0; i < accounts.accounts.length; i++)
      if (accounts.accounts[i].active) { current = i; break }
    for (var step = 1; step <= accounts.accounts.length; step++) {
      var candidate = accounts.accounts[(current + step) % accounts.accounts.length]
      if (accounts.canSwitchTo(candidate)) {
        accounts.switchTo(candidate.label)
        return
      }
    }
  }

  // ------------------------------------------------------------ measurement
  //
  // The day chart's two text columns are sized from the widest string they can
  // actually hold at the live font, not from a pixel constant. At a large font
  // scale a fixed column clips "Today" or "671.5K"; measuring keeps the bars
  // between them correct at any size.

  TextMetrics {
    id: dayLabelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    text: "Today"
  }

  TextMetrics {
    id: dayValueMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    text: "999.9M"
  }

  readonly property real dayLabelWidth: Math.ceil(dayLabelMetrics.advanceWidth) + Style.space(4)
  readonly property real dayValueWidth: Math.ceil(dayValueMetrics.advanceWidth) + Style.space(4)

  // A limit window: title and value, meter, and the pace detail underneath.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window
      && (window.severity === "high" || window.percent >= 0.9)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the value, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: root.limitValueText(limitRow.window)
        color: root.severityColor(limitRow.window)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        // A money value ("0.00 CAD of 0.00 CAD") is far longer than a
        // percentage; cap it at half the row so the title keeps a readable
        // share rather than being elided to nothing.
        width: Math.min(implicitWidth, parent.width * 0.5)
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      // The pace sentence runs long, and it is the row's most useful line, so
      // it wraps rather than eliding.
      text: root.limitDetail(limitRow.window)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.dayLabelWidth
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: Model.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.dayValueWidth
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? Model.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}

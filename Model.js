.pragma library

// Pure data shaping for the panel. Kept out of the QML so the merge rules and
// the number formatting can be reasoned about (and tested) without a running
// shell.
//
// Two sources feed this widget and neither is sufficient alone:
//
//   omarchy-agent-usage-update  writes per-agent JSON records carrying the
//                               token history -- by day and by model -- that
//                               ai-usagebar does not collect.
//   ai-usagebar usage --json    reports every configured provider with pace
//                               detail ("48% elapsed, 39pts under") and a
//                               severity, neither of which the records carry.
//
// So limits come from ai-usagebar where it has them, token history always
// comes from the records, and a provider present in only one source still
// gets a tab.

// ------------------------------------------------------------------ mapping

// The two sources name the same subscription differently. Everything else
// (zai, antigravity, openrouter, ...) exists only in ai-usagebar and keeps
// its own id.
var VENDOR_TO_AGENT = {
  "anthropic": "claude",
  "openai": "codex"
}

function agentIdForVendor(vendorId) {
  var id = String(vendorId || "")
  // Accounts arrive as `anthropic@work`; the vendor before the `@` is what
  // decides which agent record it pairs with.
  var base = id.split("@")[0]
  return VENDOR_TO_AGENT[base] || base || id
}

// --------------------------------------------------------------- primitives

function numberValue(value) {
  var n = Number(value || 0)
  return isFinite(n) ? Math.round(n) : 0
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Records use 0..1, ai-usagebar uses 0..100. Everything downstream is 0..1.
function ratioFromPercent(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return -1
  return clamp(n / 100, 0, 1)
}

function ratioFromFraction(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return -1
  return clamp(n, 0, 1)
}

function formatTokenCount(n) {
  if (n === undefined || n === null) return "0"
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(n)
}

function modelWordCase(word) {
  if (word === "gpt") return "GPT"
  if (word === "deepseek") return "DeepSeek"
  return word.charAt(0).toUpperCase() + word.slice(1)
}

// Model ids arrive hyphenated with the version split across segments
// (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one version
// and title-case the words around it.
function friendlyModelName(id) {
  if (!id) return "Unknown"
  var name = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "")
  var parts = name.split("-")
  var words = []
  var version = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    if (/^\d/.test(part)) {
      version.push(part)
      continue
    }
    if (version.length > 0) {
      words.push(version.join("."))
      version = []
    }
    words.push(modelWordCase(part))
  }
  if (version.length > 0) words.push(version.join("."))
  return words.length > 0 ? words.join(" ") : "Unknown"
}

// ------------------------------------------------------------------ windows

function windowIsLong(text) {
  return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("7d") >= 0
    || text.indexOf("seven") >= 0 || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
}

// A record's label is prose ("Session (5-hour)"), so the window has to be
// inferred from it. ai-usagebar's is already a title with the span in
// parentheses ("Session (5h)", "Fable (7d)"), so inferring would actively
// lose information: "Fable (7d)" would come back as a second "Weekly",
// indistinguishable from the real one. Strip the parenthetical and trust it.
function vendorWindowTitle(label) {
  var plain = String(label || "").replace(/\s*\([^)]*\)\s*/g, " ").trim()
  return plain === "" ? "Limit" : plain
}

function windowTitle(label) {
  var text = String(label || "").toLowerCase()
  if (text.indexOf("month") >= 0) return "Monthly"
  if (windowIsLong(text)) return "Weekly"
  if (text.indexOf("session") >= 0 || /\d+\s*-?\s*h/.test(text)) return "Session"
  return vendorWindowTitle(label)
}

// One limit window, however it was reported. `detail` and `severity` are the
// parts only ai-usagebar knows; a record-sourced window leaves them empty and
// the row simply shows one line less.
function limitWindow(label, ratio, resetAt, title, detail, severity, value) {
  return {
    title: String(title || "") !== "" ? String(title) : windowTitle(label),
    label: String(label || ""),
    percent: ratio,
    resetAt: String(resetAt || ""),
    detail: String(detail || ""),
    severity: String(severity || ""),
    value: String(value || "")
  }
}

function limitsFromRecord(record) {
  var out = []
  var list = (record && record.limits) || []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    var ratio = ratioFromFraction(entry.percent)
    if (ratio >= 0) out.push(limitWindow(entry.label, ratio, entry.resetsAt, entry.title, "", "", ""))
  }
  return out
}

function limitsFromVendor(entry) {
  var out = []
  var list = (entry && entry.metrics) || []
  for (var i = 0; i < list.length; i++) {
    var metric = list[i] || {}
    var ratio = ratioFromPercent(metric.percent)
    if (ratio < 0) continue
    out.push(limitWindow(metric.label, ratio, metric.reset_at,
                         vendorWindowTitle(metric.label),
                         metric.detail, metric.severity, metric.value))
  }
  return out
}

// The window that decides how much room is left -- the fullest one, since
// that is what stops the next prompt.
function bindingWindow(windows) {
  var best = null
  for (var i = 0; i < (windows || []).length; i++) {
    if (!best || windows[i].percent > best.percent) best = windows[i]
  }
  return best
}

function isAlarming(provider) {
  var windows = (provider && provider.limits) || []
  for (var i = 0; i < windows.length; i++) {
    if (windows[i].severity === "high") return true
    if (windows[i].percent >= 0.9) return true
  }
  if (provider && provider.balance && provider.balance.funded > 0)
    return provider.balance.remaining / provider.balance.funded <= 0.1
  return false
}

function anyAlarming(providers) {
  for (var i = 0; i < (providers || []).length; i++)
    if (isAlarming(providers[i])) return true
  return false
}

// --------------------------------------------------------------- vendor feed

// `ai-usagebar usage --json` may be absent (the binary is optional), may fail,
// or may report an entry as errored. Any of those simply means this half of
// the merge contributes nothing, never that the panel breaks.
function parseVendorFeed(text) {
  var parsed = null
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return { ok: false, entries: [], error: "ai-usagebar returned unreadable JSON" }
  }
  if (!parsed || !Array.isArray(parsed.entries))
    return { ok: false, entries: [], error: "ai-usagebar returned no entries" }
  return { ok: true, entries: parsed.entries, error: "" }
}

// Several ai-usagebar entries can map onto one agent (`anthropic` plus
// `anthropic@work`). The one without an account suffix is the subscription
// the records describe, so it wins the pairing; the others stay standalone.
function vendorByAgentId(entries) {
  var byAgent = {}
  for (var i = 0; i < (entries || []).length; i++) {
    var entry = entries[i] || {}
    var vendorId = String(entry.id || "")
    if (vendorId === "") continue
    var agentId = agentIdForVendor(vendorId)
    var plain = vendorId.indexOf("@") < 0
    if (!byAgent[agentId] || (plain && byAgent[agentId].id.indexOf("@") >= 0))
      byAgent[agentId] = entry
  }
  return byAgent
}

// ------------------------------------------------------------------- merge

function balanceValue(raw) {
  if (!raw || typeof raw !== "object") return null
  var remaining = Number(raw.remaining)
  var funded = Number(raw.funded)
  if (!isFinite(remaining) || remaining < 0) return null
  return {
    remaining: remaining,
    funded: isFinite(funded) && funded > 0 ? funded : 0,
    spent: Math.max(0, Number(raw.spent) || 0),
    currency: String(raw.currency || "USD"),
    estimated: raw.estimated === true
  }
}

function emptyHistory() {
  return {
    todayPrompts: 0, todaySessions: 0, todayTotalTokens: 0,
    todayTokensByModel: {}, recentDays: [], totalPrompts: 0,
    totalSessions: 0, activeDays: 0, modelUsage: {},
    hasLocalStats: false, hasPromptStats: false
  }
}

// Build the panel's provider from whichever halves exist.
//
//   limits   ai-usagebar when it reports this provider, records otherwise.
//            Never both: two sources for one meter would disagree on the
//            minute and flicker between refreshes.
//   history  records only. ai-usagebar does not read transcripts.
function mergeProvider(agentId, record, vendorEntry, history) {
  var stats = history || emptyHistory()
  var vendorLimits = vendorEntry ? limitsFromVendor(vendorEntry) : []
  var recordLimits = record ? limitsFromRecord(record) : []
  var limits = vendorLimits.length > 0 ? vendorLimits : recordLimits

  var name = ""
  if (vendorEntry && vendorEntry.display_name) name = String(vendorEntry.display_name)
  else if (record && record.name) name = String(record.name)
  else name = agentId

  var plan = ""
  if (vendorEntry && vendorEntry.plan) plan = String(vendorEntry.plan)
  else if (record && record.tierLabel) plan = String(record.tierLabel)

  var vendorError = vendorEntry ? String(vendorEntry.error || "") : ""
  var recordStatus = record ? String(record.usageStatusText || "") : ""

  return {
    providerId: agentId,
    providerName: name,
    // The vendor id is what `ai-usagebar` and the account switcher speak.
    vendorId: vendorEntry ? String(vendorEntry.id || "") : "",
    shortName: vendorEntry ? String(vendorEntry.short_name || "") : "",
    glyph: vendorEntry ? String(vendorEntry.icon || "") : "",
    brand: vendorEntry ? String(vendorEntry.brand || "") : "",

    ready: (record ? record.ready === true : false) || !!vendorEntry,
    // A vendor error is the more specific complaint, so it leads.
    statusText: vendorError !== "" ? vendorError : recordStatus,
    helpText: record ? String(record.authHelpText || "") : "",
    stale: vendorEntry ? vendorEntry.stale === true : false,

    limits: limits,
    limitsSource: vendorLimits.length > 0 ? "ai-usagebar" : (recordLimits.length > 0 ? "collector" : ""),
    tierLabel: plan,
    balance: balanceValue(record ? record.balance : null),

    todayPrompts: numberValue(stats.todayPrompts),
    todaySessions: numberValue(stats.todaySessions),
    todayTotalTokens: numberValue(stats.todayTotalTokens),
    todayTokensByModel: stats.todayTokensByModel || {},
    recentDays: stats.recentDays || [],
    totalPrompts: numberValue(stats.totalPrompts),
    totalSessions: numberValue(stats.totalSessions),
    activeDays: numberValue(stats.activeDays),
    modelUsage: stats.modelUsage || {},
    hasLocalStats: stats.hasLocalStats !== false,
    hasPromptStats: stats.hasPromptStats !== false,
    hasHistory: (stats.recentDays || []).length > 0
      || Object.keys(stats.modelUsage || {}).length > 0,

    syncEnabled: stats.syncEnabled === true,
    syncDeviceCount: numberValue(stats.syncDeviceCount),

    // Only Claude can have its login swapped from here, and only the plain
    // subscription entry -- a named ai-usagebar account is a separate
    // credential this tool does not own.
    supportsAccountSwitch: agentId === "claude"
  }
}

function providerHasData(p) {
  return p.limits.length > 0 || !!p.balance || p.hasHistory
    || p.totalPrompts > 0 || p.totalSessions > 0 || p.activeDays > 0
    || p.todayPrompts > 0 || p.todaySessions > 0
}

// The panel's whole provider list, ordered so the subscriptions that carry
// token history lead and vendor-only entries follow.
function buildProviders(records, historyFor, vendorEntries, isEnabled) {
  var byAgent = vendorByAgentId(vendorEntries)
  var providers = []
  var seen = {}

  for (var i = 0; i < (records || []).length; i++) {
    var record = records[i]
    if (!record || !record.id) continue
    var agentId = String(record.id)
    if (seen[agentId]) continue
    if (isEnabled && !isEnabled(agentId)) continue
    seen[agentId] = true
    var merged = mergeProvider(agentId, record, byAgent[agentId] || null,
                               historyFor ? historyFor(agentId, record) : null)
    if (providerHasData(merged)) providers.push(merged)
  }

  for (var agentId2 in byAgent) {
    if (seen[agentId2]) continue
    if (isEnabled && !isEnabled(agentId2)) continue
    seen[agentId2] = true
    var vendorOnly = mergeProvider(agentId2, null, byAgent[agentId2],
                                   historyFor ? historyFor(agentId2, null) : null)
    if (providerHasData(vendorOnly)) providers.push(vendorOnly)
  }

  return providers
}

function indexOfProvider(providers, providerId) {
  for (var i = 0; i < (providers || []).length; i++)
    if (providers[i].providerId === providerId) return i
  return -1
}

// ------------------------------------------------------------------ bar

// What the bar button paints. One chip per provider when `showAll`, otherwise
// just the selected one. `barWindow` pins which meter the number comes from,
// falling back to the fullest window when a provider lacks that one.
function chipFor(provider, barWindow, showValue, showProvider) {
  var windows = provider.limits || []
  var chosen = null
  var wanted = String(barWindow || "auto")
  if (wanted !== "auto") {
    for (var i = 0; i < windows.length; i++) {
      var title = String(windows[i].title || "").toLowerCase()
      if (wanted === "session" && title.indexOf("session") >= 0) { chosen = windows[i]; break }
      if (wanted === "weekly" && title.indexOf("week") >= 0) { chosen = windows[i]; break }
      if (wanted === "monthly" && title.indexOf("month") >= 0) { chosen = windows[i]; break }
    }
  }
  if (!chosen) chosen = bindingWindow(windows)

  var label = ""
  if (showValue !== false) {
    if (chosen && chosen.percent >= 0) label = Math.round(chosen.percent * 100) + "%"
    else if (provider.balance) label = String(Math.round(provider.balance.remaining))
  }
  if (showProvider === true && provider.shortName !== "")
    label = label === "" ? provider.shortName : provider.shortName + " " + label

  return {
    providerId: provider.providerId,
    glyph: provider.glyph || "",
    label: label,
    alarming: isAlarming(provider)
  }
}

function barChips(providers, selectedId, showAll, showValue, showProvider, barWindow) {
  var list = providers || []
  if (list.length === 0) return []
  if (showAll === true) {
    var chips = []
    for (var i = 0; i < list.length; i++)
      chips.push(chipFor(list[i], barWindow, showValue, showProvider))
    return chips
  }
  var index = Math.max(0, indexOfProvider(list, selectedId))
  return [chipFor(list[index], barWindow, showValue, showProvider)]
}

// ------------------------------------------------------------------ accounts

// The switcher's view of `omarchy-claude-account status --json`. Parsed
// defensively: a missing or broken helper disables the control rather than
// breaking the panel it sits in.
function parseAccountStatus(text) {
  var parsed = null
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return emptyAccountStatus("Could not read the account helper's output")
  }
  if (!parsed || typeof parsed !== "object")
    return emptyAccountStatus("The account helper returned nothing usable")

  var activity = parsed.activity || {}
  var accounts = []
  var list = Array.isArray(parsed.accounts) ? parsed.accounts : []
  for (var i = 0; i < list.length; i++) {
    var account = list[i] || {}
    accounts.push({
      label: String(account.label || ""),
      active: account.active === true,
      ready: account.ready === true,
      email: String(account.email || ""),
      organizationName: String(account.organizationName || ""),
      storedInKeyring: account.storedInKeyring === true
    })
  }

  return {
    ok: true,
    accounts: accounts,
    activeLabel: String(parsed.activeLabel || ""),
    activeEmail: String((parsed.activeIdentity || {}).emailAddress || ""),
    activeOrg: String((parsed.activeIdentity || {}).organizationName || ""),
    unmanagedActive: parsed.unmanagedActive === true,
    keyringAvailable: parsed.keyringAvailable !== false,
    keyringMessage: String(parsed.keyringMessage || ""),
    busy: activity.busy === true,
    running: activity.running === true,
    canSwitch: activity.canSwitch === true,
    blockedReason: String(activity.reason || ""),
    error: ""
  }
}

function emptyAccountStatus(error) {
  return {
    ok: false, accounts: [], activeLabel: "", activeEmail: "", activeOrg: "",
    unmanagedActive: false, keyringAvailable: false, keyringMessage: "",
    busy: false, running: false, canSwitch: false, blockedReason: "",
    error: String(error || "")
  }
}

// Why a given account's button is not clickable, or "" when it is. The panel
// shows this as the control's tooltip, so a greyed-out button always explains
// itself rather than just refusing.
function switchBlockedReason(status, account) {
  if (!status || !status.ok) return status && status.error ? status.error : "Account switching is unavailable"
  if (account && account.active) return "Already the active account"
  if (!status.keyringAvailable) return status.keyringMessage || "The login keyring is unavailable"
  if (account && !account.ready) return "No stored credential — sign this account in first"
  if (!status.canSwitch) return status.blockedReason || "A Claude session is running"
  if (status.unmanagedActive) return "The active login has no label yet — adopt it before switching away"
  return ""
}

function booleanSetting(value, fallback) {
  if (value === true || value === false) return value
  var text = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  if (text === "true" || text === "on" || text === "yes" || text === "1") return true
  if (text === "false" || text === "off" || text === "no" || text === "0") return false
  return fallback
}

function normalizeBarWindow(value) {
  var text = String(value || "auto").trim().toLowerCase()
  if (text === "session" || text === "weekly" || text === "monthly") return text
  return "auto"
}

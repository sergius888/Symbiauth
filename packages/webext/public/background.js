const HOST_NAME = "com.armadillo.nmhost";

let port = null;
let lastRequest = null;
let pendingStepUp = null;
let pendingFill = null;
let pendingRetry = null;
let lastHeartbeatAt = 0;
let lastProx = null;
let lastVault = null;
let proxStatusTimeout = null;
let vaultStatusTimeout = null;
let statusPollTimer = null;

function isProxNear(prox) {
  if (!prox) return false;
  if (prox.state === "far" || prox.state === "offline") return false;
  if (prox.near === false) return false;
  return true;
}

function isVaultUnlocked(vault) {
  return !!(vault && vault.unlocked);
}

function updateBadge(prox, vault) {
  const near = isProxNear(prox);
  const unlocked = isVaultUnlocked(vault);
  if (near && unlocked) {
    chrome.action.setBadgeText({ text: "" });
    return;
  }
  // If offline/far or locked, show red "L"
  chrome.action.setBadgeBackgroundColor({ color: "#d9534f" });
  chrome.action.setBadgeText({ text: "L" });
}

function corrId() {
  return crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(16).slice(2);
}

function sendHeartbeat() {
  // Heartbeat now only from TLS; extension no longer sends prox.heartbeat
}

function connectNativeHost() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (err) {
    console.error("[armadillo] connectNative failed:", err);
    port = null;
    return;
  }

  port.onMessage.addListener((msg) => {
    try {
      console.log("[armadillo] nm recv:", JSON.stringify(msg));
    } catch (_) {
      console.log("[armadillo] nm recv:", msg);
    }

    // TOTP step-up path
    if (msg?.type === "error" && msg.err_reason === "step_up_totp_required") {
      if (lastRequest?.origin) {
        pendingStepUp = { origin: lastRequest.origin, action: lastRequest.action || "cred.get" };
        chrome.action.openPopup();
      }
      return;
    }

    if (msg?.type === "ok" && msg.reason === "totp_verified") {
      if (lastRequest && port) {
        port.postMessage(lastRequest);
      }
      return;
    }

    // Auto move from list -> get
    if (msg?.type === "cred.accounts" && Array.isArray(msg.accounts)) {
      if (msg.accounts.length === 0) {
        console.warn("[armadillo] no accounts for origin", msg.origin);
        return;
      }
      const account = msg.accounts[0]; // simple: first account
      const req = {
        type: "cred.get",
        origin: msg.origin,
        username: account.username,
        action: "cred.get",
        corr_id: corrId(),
      };
      lastRequest = req;
      pendingFill = { origin: msg.origin, username: account.username };
      port?.postMessage(req);
      return;
    }

    // Fill when secret arrives
    if (msg?.type === "cred.secret" && msg.password_b64) {
      // Success: clear any pending retry and badge
      pendingRetry = null;
      chrome.action.setBadgeText({ text: "" });
      const pwd = atob(msg.password_b64);
      const username = msg.username || pendingFill?.username || "";
      chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
        const tabId = tabs[0]?.id;
        if (!tabId) return;
        chrome.tabs.sendMessage(tabId, {
          type: "fill.form",
          origin: msg.origin,
          username,
          password: pwd,
        });
      });
      return;
    }

  if (msg?.type === "error") {
    const reason = msg.err_reason || msg.err_code || msg.message || "";
    const friendly =
      reason === "proximity_far"
        ? "Phone away/offline. Bring it near to unlock."
        : reason;
    console.warn("[armadillo] native host error", friendly || msg);
      // If locked or proximity error, schedule one auto-retry after Face ID
      if (
        reason === "UNLOCK_REQUIRED" ||
        reason === "unlock required" ||
        reason === "session_unlock_required" ||
        reason === "proximity_far"
      ) {
        chrome.action.setBadgeBackgroundColor({ color: "#d9534f" }); // red
        chrome.action.setBadgeText({ text: "L" });
        if (lastRequest) {
          pendingRetry = { req: lastRequest, attempts: 0 };
          scheduleRetry();
        }
      }
      return;
    }

    if (msg?.type === "auth.request") {
      console.warn("[armadillo] auth.request – vault locked or session required");
      chrome.action.setBadgeBackgroundColor({ color: "#f0ad4e" }); // orange
      chrome.action.setBadgeText({ text: "L" });
      if (lastRequest) {
        pendingRetry = { req: lastRequest, attempts: 0 };
        scheduleRetry();
      }
      return;
    }

    // Start passive status polling so popup stays fresh without user clicks
    startStatusPoll();

    // prox/vault status caching for popup
    if (msg?.type === "prox.status") {
      clearTimeout(proxStatusTimeout);
      lastProx = msg;
      updateBadge(lastProx, lastVault);
      chrome.runtime.sendMessage({ type: "popup.status.update", prox: msg });
      return;
    }
    if (msg?.type === "vault.ack" && msg.op === "status") {
      clearTimeout(vaultStatusTimeout);
      lastVault = msg;
      updateBadge(lastProx, lastVault);
      chrome.runtime.sendMessage({ type: "popup.status.update", vault: msg });
      return;
    }
  });

  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || "unknown";
    console.warn("[armadillo] nm disconnected:", err);
    port = null;
    stopStatusPoll();
    // Mark offline
    const offlineProx = { type: "prox.status", state: "offline", near: false, unlocked: false };
    const offlineVault = { type: "vault.ack", op: "status", unlocked: false, offline: true };
    lastProx = offlineProx;
    lastVault = offlineVault;
    chrome.runtime.sendMessage({ type: "popup.status.update", prox: offlineProx, vault: offlineVault });
  });

  port.postMessage({
    type: "nm.hello",
    proto: "armadillo.webext",
    version: 1,
    min_compatible: 1,
  });
}

chrome.runtime.onInstalled.addListener(() => connectNativeHost());
chrome.runtime.onStartup.addListener(() => connectNativeHost());

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "ui.fill.clicked") {
    if (!port) connectNativeHost();
    const origin = message.origin || "";
    // Block immediately if proximity or vault not OK
    if (!isProxNear(lastProx) || !isVaultUnlocked(lastVault)) {
      chrome.action.setBadgeBackgroundColor({ color: "#d9534f" });
      chrome.action.setBadgeText({ text: "L" });
      console.warn("[armadillo] fill blocked: proximity far/offline or vault locked");
      return;
    }
    const req = {
      type: "cred.list",
      origin,
      corr_id: corrId(),
    };
    lastRequest = req;
    chrome.action.setBadgeText({ text: "" });
    port?.postMessage(req);
  }

  if (message?.type === "popup.totp.submit") {
    if (!port || !pendingStepUp) return;
    const req = {
      type: "auth.totp",
      origin: pendingStepUp.origin,
      action: pendingStepUp.action,
      code: message.code,
      corr_id: corrId(),
    };
    port.postMessage(req);
  }

  if (message?.type === "popup.status.request") {
    if (!port) connectNativeHost();
    // respond with cached if present
    if (lastProx || lastVault) {
      chrome.runtime.sendMessage({ type: "popup.status.update", prox: lastProx, vault: lastVault });
    }
    const cid = corrId();
    // request fresh status
    port?.postMessage({ type: "prox.status", corr_id: cid });
    port?.postMessage({ type: "vault.status", corr_id: corrId() });
    // set offline fallbacks if no response arrives soon
    proxStatusTimeout = setTimeout(() => {
      const offline = { type: "prox.status", state: "offline", near: false, unlocked: false };
      lastProx = offline;
      chrome.runtime.sendMessage({ type: "popup.status.update", prox: offline });
    }, 1200);
    vaultStatusTimeout = setTimeout(() => {
      const offline = { type: "vault.ack", op: "status", unlocked: false, offline: true };
      lastVault = offline;
      chrome.runtime.sendMessage({ type: "popup.status.update", vault: offline });
    }, 1200);
  }
});

// Auto-retry the last request once after Face ID approval completes
function scheduleRetry() {
    if (!pendingRetry || pendingRetry.attempts >= 1) return;
    pendingRetry.attempts += 1;
    setTimeout(() => {
      if (!pendingRetry || !pendingRetry.req) return;
      if (!port) connectNativeHost();
      const clone = { ...pendingRetry.req, corr_id: corrId() };
      lastRequest = clone;
      port?.postMessage(clone);
    }, 1200);
  }

function startStatusPoll() {
  if (statusPollTimer) return;
  statusPollTimer = setInterval(() => {
    if (!port) return;
    port.postMessage({ type: "prox.status", corr_id: corrId() });
    port.postMessage({ type: "vault.status", corr_id: corrId() });
  }, 5000);
}

function stopStatusPoll() {
  if (statusPollTimer) {
    clearInterval(statusPollTimer);
    statusPollTimer = null;
  }
}

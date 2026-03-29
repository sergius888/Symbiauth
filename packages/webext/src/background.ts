const HOST_NAME = "com.armadillo.nmhost";

let port: chrome.runtime.Port | null = null;
let lastRequest: any = null;
let pendingStepUp:
  | { origin: string; action: string }
  | null = null;
let pendingFill: { origin: string; username?: string } | null = null;

function corrId(): string {
  return crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(16).slice(2);
}

function connectNativeHost() {
  console.log("[armadillo] connecting to native host");
  port = chrome.runtime.connectNative(HOST_NAME);

  port.onMessage.addListener((msg) => {
    console.log("[armadillo] nm recv:", msg);
    // Handle step-up and retry
    if (msg?.type === "error" && msg.err_reason === "step_up_totp_required") {
      if (lastRequest?.origin) {
        pendingStepUp = { origin: lastRequest.origin, action: lastRequest.action || "cred.get" };
        chrome.action.openPopup();
      }
    }
    if (msg?.type === "ok" && msg.reason === "totp_verified") {
      if (lastRequest && port) {
        port.postMessage(lastRequest);
      }
    }

    // Auto-request credential after listing
    if (msg?.type === "cred.accounts" && Array.isArray(msg.accounts)) {
      if (msg.accounts.length === 0) {
        console.warn("[armadillo] no accounts for origin", msg.origin);
        return;
      }
      const account = msg.accounts[0]; // simple first match
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
    }

    // Fill form when secret arrives
    if (msg?.type === "cred.secret" && msg.password_b64) {
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
    }
  });

  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || "unknown";
    console.warn("[armadillo] nm disconnected:", err);
    port = null;
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
    const req = {
      type: "cred.list",
      origin,
      corr_id: corrId(),
    };
    lastRequest = req;
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
});

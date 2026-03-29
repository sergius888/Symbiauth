const sendBtn = document.getElementById("send");
const codeInput = document.getElementById("code");
const proxState = document.getElementById("prox-state");
const vaultState = document.getElementById("vault-state");
const statusMsg = document.getElementById("status-msg");

sendBtn.addEventListener("click", () => {
  const code = codeInput.value.trim();
  if (!code) return;
  chrome.runtime.sendMessage({ type: "popup.totp.submit", code });
  window.close();
});

function renderStatus(msg) {
  if (msg?.type === "prox.status") {
    const state = msg.state || (msg.near ? "near" : "far") || "–";
    const age = msg.last_heartbeat_age_ms;
    if (age === undefined || age === null) {
      proxState.textContent = `${state} (offline)`;
    } else {
      proxState.textContent = `${state} (${age}ms)`;
    }
    // If proximity is far/offline, show a friendly note
    if (!msg.near || msg.state === "far" || msg.state === "offline") {
      statusMsg.textContent = "Phone away/offline. Bring it near to unlock.";
      statusMsg.style.display = "block";
    } else {
      statusMsg.textContent = "";
      statusMsg.style.display = "none";
    }
  }
  if (msg?.type === "vault.ack" && msg.op === "status") {
    // NOTE: Today this reflects the global vault lock. In the future, we may show
    // per-site lock intent (e.g., user chooses extra step-up for certain origins
    // even while the vault is globally unlocked).
    vaultState.textContent = msg.unlocked ? "unlocked" : "locked";
  }
}

chrome.runtime.sendMessage({ type: "popup.status.request" });

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.type === "popup.status.update") {
    if (msg.prox) renderStatus(msg.prox);
    if (msg.vault) renderStatus(msg.vault);
  }
  renderStatus(msg);
});

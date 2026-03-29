const BUTTON_ID = "armadillo-fill-button";

function injectButton() {
  if (document.getElementById(BUTTON_ID)) {
    return;
  }

  const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement | null;
  if (!passwordInput) {
    return;
  }

  const btn = document.createElement("button");
  btn.id = BUTTON_ID;
  btn.textContent = "Fill with Armadillo";
  btn.type = "button";
  btn.style.cssText = "margin:6px 0;padding:6px 10px;font:12px system-ui;";
  btn.addEventListener("click", () => {
    chrome.runtime.sendMessage({
      type: "ui.fill.clicked",
      origin: window.location.origin,
    });
  });

  const target = passwordInput.closest("form") ?? passwordInput.parentElement ?? document.body;
  target?.insertBefore(btn, target.firstChild);
}

function setValue(el: HTMLInputElement, value: string) {
  const nativeInputValueSetter = Object.getOwnPropertyDescriptor(el.__proto__, 'value')?.set;
  nativeInputValueSetter?.call(el, value);
  const ev = new Event('input', { bubbles: true });
  el.dispatchEvent(ev);
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.type === "fill.form") {
    const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement | null;
    if (passwordInput && msg.password) {
      setValue(passwordInput, msg.password);
    }
    const userInput = document.querySelector('input[type="text"], input[type="email"], input[name*="user"], input[name*="email"]') as HTMLInputElement | null;
    if (userInput && msg.username) {
      setValue(userInput, msg.username);
    }
  }
});

if (document.readyState === "complete" || document.readyState === "interactive") {
  injectButton();
} else {
  document.addEventListener("DOMContentLoaded", injectButton);
}

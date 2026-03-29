(() => {
  const BUTTON_ID = "armadillo-fill-button";

  function injectButton() {
    if (document.getElementById(BUTTON_ID)) return;

    const passwordInput = document.querySelector('input[type="password"]');
    if (!passwordInput) return;

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

  function setValue(el, value) {
    if (!el) return;
    const setter = Object.getOwnPropertyDescriptor(el.__proto__, "value")?.set;
    setter?.call(el, value);
    const ev = new Event("input", { bubbles: true });
    el.dispatchEvent(ev);
  }

  function findPasswordField() {
    // Prefer visible password inputs
    const candidates = Array.from(document.querySelectorAll('input[type="password"]'));
    const visible = candidates.find((el) => el.offsetParent !== null);
    return visible || candidates[0] || null;
  }

  function isLikelyUsername(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    const type = (el.type || "").toLowerCase();
    if (["text", "email", "tel"].includes(type) || type === "") {
      const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
      if (["username", "email", "webauthn", "identifier"].some((t) => ac.includes(t))) return true;
      const name = (el.name || "").toLowerCase();
      const id = (el.id || "").toLowerCase();
      if (["user", "email", "login", "identifier"].some((t) => name.includes(t) || id.includes(t)))
        return true;
    }
    return false;
  }

  function findUsernameField() {
    // Strategy: 1) autocomplete username/email, 2) same form as password, 3) any likely username input
    const form = (() => {
      const pwd = findPasswordField();
      return pwd ? pwd.form : null;
    })();

    const inForm =
      form &&
      Array.from(form.elements).find(
        (el) =>
          el instanceof HTMLInputElement &&
          ["username", "email"].includes((el.getAttribute("autocomplete") || "").toLowerCase())
      );
    if (inForm) return inForm;

    const likelyInForm =
      form &&
      Array.from(form.elements).find((el) => el instanceof HTMLInputElement && isLikelyUsername(el));
    if (likelyInForm) return likelyInForm;

    const anyAuto =
      document.querySelector('input[autocomplete="username"], input[autocomplete="email"]');
    if (anyAuto) return anyAuto;

    const anyLikely = Array.from(
      document.querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input:not([type])')
    ).find((el) => isLikelyUsername(el));
    return anyLikely || null;
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === "fill.form") {
      const pwdInput = findPasswordField();
      if (pwdInput && msg.password) setValue(pwdInput, msg.password);
      const userInput = findUsernameField();
      if (userInput && msg.username) setValue(userInput, msg.username);
    }
  });

  if (document.readyState === "complete" || document.readyState === "interactive") {
    injectButton();
  } else {
    document.addEventListener("DOMContentLoaded", injectButton);
  }
})();

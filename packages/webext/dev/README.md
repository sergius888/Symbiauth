# Dev-only assets for the Chrome extension

This directory is **not** packaged with the extension. Use it to keep the developer
key material that gives the extension a stable ID for Native Messaging.

Steps to (re)generate the dev key:

```bash
mkdir -p packages/webext/dev
openssl genrsa -out packages/webext/dev/dev_key.pem 2048
openssl rsa -in packages/webext/dev/dev_key.pem -pubout -outform DER \
  | base64 > packages/webext/dev/public_key_base64.txt
```

* `dev_key.pem` (private) is gitignored. Keep it local only.
* Copy the single-line contents of `public_key_base64.txt` into
  `public/manifest.json` under the `"key"` field so Chrome derives a stable ID.
* Record the resulting extension ID (from `chrome://extensions`) inside
  `~/.armadillo/dev_extension_id.txt` or export it via `ARM_WEBEXT_DEV_ID`
  so the macOS app can install the Native Messaging manifest.



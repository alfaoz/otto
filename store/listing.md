# Chrome Web Store listing

Upload `build/otto-extension.zip` (`tools/extension-zip.sh` makes it).

## Store listing

Name and summary come from the manifest.

Category: Productivity > Developer Tools
Language: English
Homepage: https://otto.alfaoz.dev
Support: https://github.com/alfaoz/otto/issues
Icon: comes from the zip (`icons/tile-128.png`)
Screenshots: `screenshot-1.png`, `screenshot-2.png`, `screenshot-3.png`
Small promo tile: `promo-440x280.png`

Description:

```
otto is a password vault your coding agents can use. this extension is how otto reaches your browser.

it needs the otto app for Mac (macOS 26 or later), which is free: https://otto.alfaoz.dev

when an agent asks, otto can:
- fill a login into the tab on that login's own site
- fill a 2FA code
- fill a card into a checkout, after you approve it. it never presses pay
- read a 2FA setup QR code from the tab

your agent only hears whether it worked. the passwords stay on your Mac.

you decide in otto which logins agents can use, and whether each use asks for your Touch ID.

the extension only talks to otto on your Mac. it sends nothing over the network.

the source code is at https://github.com/alfaoz/otto (GPL-3.0).
```

## Privacy

Single purpose:

```
Fills logins, 2FA codes and cards from the user's otto vault (a Mac app) into web pages when the user's coding agent asks for it.
```

Permission justifications:

nativeMessaging
```
The extension talks to the otto app on the same Mac through native messaging. That's where the fill requests and the values to fill come from.
```

scripting
```
Fills login, 2FA and card fields on the page, and finds a 2FA setup QR code on it, by running the extension's own functions in the tab.
```

tabs
```
Reads the addresses of open tabs to find the one on the site a login belongs to, because otto only fills a login on its own sites. Also takes a picture of the visible tab when an agent asks otto to read a 2FA setup QR code.
```

offscreen
```
A hidden page watches light and dark mode, which a service worker can't see, so the toolbar icon can match it.
```

Host permission (all sites)
```
A user's logins can be on any website, including their own servers and intranet sites, and card fields can be inside a payment provider's frame. otto only fills on the sites the user saved for that login, or on a domain the user approved.
```

Remote code: No, I am not using remote code.

Data usage. Tick these (Google asks for this even when data stays on the device):
- Personally identifiable information (usernames, cardholder names)
- Financial and payment information (cards)
- Authentication information (passwords, 2FA codes)
- Web history (addresses of open tabs)
- Website content (form fields, the picture of a tab for a QR code)

Tick all three certifications.

Privacy policy: https://otto.alfaoz.dev/privacy

## Test instructions

Username: tomsmith
Password: SuperSecretPassword! (both public, for a test site)
Additional instructions (500 characters at most):

```
Needs a Mac on macOS 26 or later.

1. Install otto from https://otto.alfaoz.dev and open it.
2. Click this extension's icon. It should say "connected".
3. In otto, add a login named test, site the-internet.herokuapp.com, with the username and password above.
4. Open https://the-internet.herokuapp.com/login
5. In Terminal: /Applications/Otto.app/Contents/MacOS/otto fill test
6. Approve when otto asks. The form fills and submits, and the page says you're logged in.
```

## Distribution

Choose to publish manually after review, so it goes live when otto's download does.

# keylog probe

A single static page (no build, not shipped in the app) that logs every keyboard event sequence a
text field receives, for seeding the autocorrect corpus (plans#105 X1) and learning whether
`window.EditContext` exists on a phone.

One JSON object per line, `t` in ms since load: `keydown`/`keyup`, `beforeinput` (`inputType`,
`data`, `dataTransfer`, `targetRanges`), `input`, `compositionstart/update/end` and
`selectionchange`, each with the field's `value` and selection after it. The first line
(`type: "env"`) has the user agent, brands and `editContext` availability.

## Open it

Serve the directory over the LAN and open it on the phone:

    cd tools/keylog && python3 -m http.server 8000

Then browse to `http://<computer-ip>:8000/` (same Wi-Fi). Over plain HTTP the Copy button uses a
fallback that selects the log and runs `execCommand("copy")`; over HTTPS or localhost it uses the
Clipboard API. For USB, `chrome://inspect` port forwarding (forward 8000) gives
`http://localhost:8000/`.

## Get the log back

- **Copy log** puts the JSON lines on the clipboard; paste them into a message or file.
- **POST log** sends them as `application/x-ndjson` to the URL given in the query string:
  `http://<computer-ip>:8000/?post=http://<computer-ip>:9000/log`. The receiver must allow CORS
  (`Access-Control-Allow-Origin: *` and answer the preflight `OPTIONS`).

Type words with autocorrect/suggestions on, accept a suggestion, swipe, replace a word, then copy.

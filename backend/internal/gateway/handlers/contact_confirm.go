package handlers

import (
	"html/template"
	"net/http"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// The trusted-contact confirmation page (#80, decision D2).
//
// Adding someone as a trusted contact texts them a link to /c/{token}. This
// is where they agree. It is the one place in the gateway that serves HTML,
// and it is built so that nothing but a deliberate press of the button can
// confirm anyone:
//
//   - GET only shows the page. SMS and chat apps fetch links on their own to
//     draw previews, and a GET that confirmed would let a preview agree on
//     the contact's behalf. The button POSTs.
//   - The token is the whole credential, so it must not leak: no-referrer,
//     no caching, and no outbound links or resources on the page at all.
//   - It cannot be framed, so the button cannot be dressed up as something
//     else on another site.
//
// The page works for every app version already installed, because the app
// is not involved: the contact needs only a browser.

var contactConfirmPage = template.Must(template.New("confirm").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>TieHere emergency contact</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 17px/1.5 system-ui, -apple-system, sans-serif;
         background: #f4f6f8; color: #070d15; }
  main { max-width: 26rem; margin: 12vh auto; padding: 0 1.25rem; }
  h1 { font-size: 1.4rem; line-height: 1.25; margin: 0 0 .75rem; }
  p { margin: 0 0 1rem; color: #3b4652; }
  button { width: 100%; padding: .9rem; border: 0; border-radius: .75rem;
           background: #34c24c; color: #fff; font: inherit; font-weight: 600; }
  .done { color: #1f7a31; }
  @media (prefers-color-scheme: dark) {
    body { background: #070d15; color: #f4f6f8; }
    p { color: #aab4bf; }
    .done { color: #5fd877; }
  }
</style>
</head>
<body>
<main>
{{if eq .State "ask"}}
  <h1>Agree to be an emergency contact?</h1>
  <p>Someone on TieHere asked to add you as their emergency contact. If you agree, you will get a text with their location if they ever press SOS.</p>
  <form method="post">
    <button type="submit">I agree</button>
  </form>
  <p>If you do not agree, close this page. Nothing else happens.</p>
{{else if eq .State "done"}}
  <h1 class="done">You are now {{.Name}}'s emergency contact.</h1>
  <p>If they press SOS on TieHere, you will get a text with their location. You can close this page.</p>
{{else}}
  <h1>This link has expired or was already used.</h1>
  <p>Ask the person who added you to remove you and add you again, and a new link will be sent.</p>
{{end}}
</main>
</body>
</html>
`))

type contactConfirmView struct {
	State string // "ask", "done" or "gone"
	Name  string
}

func writeContactConfirmPage(w http.ResponseWriter, code int, view contactConfirmView) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Content-Type-Options", "nosniff")
	// No scripts, no external anything; the form posts back to itself.
	h.Set("Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
	w.WriteHeader(code)
	_ = contactConfirmPage.Execute(w, view)
}

// showContactConfirm answers GET: it only asks. See the file comment for
// why a GET must never confirm.
func (h *Handler) showContactConfirm(w http.ResponseWriter, _ *http.Request) {
	writeContactConfirmPage(w, http.StatusOK, contactConfirmView{State: "ask"})
}

// confirmContact answers the button.
func (h *Handler) confirmContact(w http.ResponseWriter, r *http.Request) {
	name, err := h.monolith.ConfirmTrustedContact(r.Context(), r.PathValue("token"))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			writeContactConfirmPage(w, http.StatusNotFound, contactConfirmView{State: "gone"})
			return
		}
		h.logger.Error("confirm trusted contact", "error", err)
		writeContactConfirmPage(w, http.StatusServiceUnavailable, contactConfirmView{State: "gone"})
		return
	}
	writeContactConfirmPage(w, http.StatusOK, contactConfirmView{State: "done", Name: name})
}

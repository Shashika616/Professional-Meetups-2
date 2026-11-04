package analytics

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// #116: what the GCS uploader sends and how it reads a 412.
func TestGCSCreateOnlyUploadTreatsPreconditionFailedAsDone(t *testing.T) {
	var gotQuery string
	status := http.StatusPreconditionFailed
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			_, _ = io.WriteString(w, `{"access_token":"t","expires_in":3600}`)
			return
		}
		gotQuery = r.URL.RawQuery
		w.WriteHeader(status)
	}))
	defer srv.Close()
	g := &GCS{client: &http.Client{Timeout: 5 * time.Second}, tokenURL: srv.URL + "/token", uploadBase: srv.URL + "/upload/"}

	if err := g.Upload(context.Background(), "b", "analytics/reports/x.xlsx", []byte("x"), UploadOptions{CreateOnly: true}); err != nil {
		t.Errorf("a create-only upload of an existing object failed: %v", err)
	}
	if want := "ifGenerationMatch=0"; !contains(gotQuery, want) {
		t.Errorf("query %q does not carry %s", gotQuery, want)
	}
	if err := g.Upload(context.Background(), "b", "o", []byte("x"), UploadOptions{}); err == nil {
		t.Error("a 412 on a plain upload counted as done")
	}
	status = http.StatusForbidden
	if err := g.Upload(context.Background(), "b", "o", []byte("x"), UploadOptions{CreateOnly: true}); err == nil {
		t.Error("a 403 counted as done")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// fakeResumable is a Cloud Storage resumable-upload endpoint, strict about
// the protocol: initiation names the object and carries the precondition,
// every chunk but the last is a multiple of 256 KiB with an open total,
// and the last states the total.
type fakeResumable struct {
	t        *testing.T
	got      bytes.Buffer
	chunks   int
	initArgs string
	exists   bool
}

func (f *fakeResumable) handler(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/token":
		_, _ = io.WriteString(w, `{"access_token":"t","expires_in":3600}`)
	case r.Method == http.MethodPost:
		f.initArgs = r.URL.RawQuery
		if f.exists {
			w.WriteHeader(http.StatusPreconditionFailed)
			return
		}
		w.Header().Set("Location", "http://"+r.Host+"/session/1")
		w.WriteHeader(http.StatusOK)
	case r.Method == http.MethodPut && r.URL.Path == "/session/1":
		body, _ := io.ReadAll(r.Body)
		cr := r.Header.Get("Content-Range")
		f.chunks++
		f.got.Write(body)
		if strings.HasSuffix(cr, "/*") {
			if len(body)%(256<<10) != 0 {
				f.t.Errorf("an intermediate chunk of %d bytes is not a multiple of 256 KiB", len(body))
			}
			w.WriteHeader(http.StatusPermanentRedirect) // 308 Resume Incomplete
			return
		}
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusBadRequest)
	}
}

// #119 (review N1-L1): the archive was gzipped whole in memory before
// upload. It now streams in fixed chunks through a resumable upload.
func TestGCSStreamsAnArchiveInChunks(t *testing.T) {
	f := &fakeResumable{t: t}
	srv := httptest.NewServer(http.HandlerFunc(f.handler))
	defer srv.Close()
	g := &GCS{client: &http.Client{Timeout: 5 * time.Second}, tokenURL: srv.URL + "/token", uploadBase: srv.URL + "/upload/", chunkSize: 256 << 10}

	want := bytes.Repeat([]byte("0123456789"), 70_000) // 700,000 bytes: three chunks
	if err := g.UploadStream(context.Background(), "b", "analytics/raw/x.ndjson.gz", bytes.NewReader(want), UploadOptions{CreateOnly: true}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(f.got.Bytes(), want) {
		t.Errorf("uploaded %d bytes, want %d intact", f.got.Len(), len(want))
	}
	if f.chunks != 3 {
		t.Errorf("%d chunks, want 3", f.chunks)
	}
	if !strings.Contains(f.initArgs, "uploadType=resumable") || !strings.Contains(f.initArgs, "ifGenerationMatch=0") {
		t.Errorf("initiation %q is not a create-only resumable upload", f.initArgs)
	}

	// An archive already there is done, as for a plain upload.
	f2 := &fakeResumable{t: t, exists: true}
	srv2 := httptest.NewServer(http.HandlerFunc(f2.handler))
	defer srv2.Close()
	g.tokenURL, g.uploadBase, g.token = srv2.URL+"/token", srv2.URL+"/upload/", ""
	if err := g.UploadStream(context.Background(), "b", "o", bytes.NewReader(want), UploadOptions{CreateOnly: true}); err != nil {
		t.Errorf("an existing archive: %v, want done", err)
	}
}

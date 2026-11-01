package analytics

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"professional-meetups-monolith/backend/internal/modules/analytics/repository/sqlcgen"
)

// UploadOptions says how an object is written.
type UploadOptions struct {
	ContentType string
	// CreateOnly refuses to replace an existing object (the raw archive:
	// written once). The daily report is regenerated in place instead.
	CreateOnly bool
}

// Uploader writes one object to Cloud Storage.
type Uploader interface {
	Upload(ctx context.Context, bucket, object string, body []byte, opts UploadOptions) error
}

func markArchived(d time.Time, uri string) sqlcgen.MarkPartitionArchivedParams {
	return sqlcgen.MarkPartitionArchivedParams{Day: date(d), Uri: textKey(uri)}
}

// The endpoints are fixed: the metadata server for the Cloud Run service
// account's token, and the Cloud Storage JSON API. Nothing in a request or
// the environment can point the archive anywhere else.
const (
	metadataTokenURL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
	gcsUploadBase    = "https://storage.googleapis.com/upload/storage/v1/b/"
)

// GCS uploads through the JSON API as the Cloud Run service account, whose
// token comes from the metadata server. No key file, no SDK.
type GCS struct {
	client     *http.Client
	tokenURL   string
	uploadBase string

	mu      sync.Mutex
	token   string
	expires time.Time
}

// NewGCS constructs the uploader.
func NewGCS() *GCS {
	return &GCS{client: &http.Client{Timeout: 60 * time.Second}, tokenURL: metadataTokenURL, uploadBase: gcsUploadBase}
}

func (g *GCS) accessToken(ctx context.Context) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.token != "" && time.Now().Before(g.expires) {
		return g.token, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.tokenURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := g.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("analytics: metadata token: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("analytics: metadata token: status %d", resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&body); err != nil || body.AccessToken == "" {
		return "", fmt.Errorf("analytics: metadata token: unreadable response")
	}
	g.token = body.AccessToken
	g.expires = time.Now().Add(time.Duration(body.ExpiresIn)*time.Second - time.Minute)
	return g.token, nil
}

// Upload writes the object. With CreateOnly, ifGenerationMatch=0 makes it
// create-only: a retry after an upload that succeeded but was not recorded
// gets 412, which means the object is already there, so it counts as done.
func (g *GCS) Upload(ctx context.Context, bucket, object string, body []byte, opts UploadOptions) error {
	token, err := g.accessToken(ctx)
	if err != nil {
		return err
	}
	params := url.Values{"uploadType": {"media"}, "name": {object}}
	if opts.CreateOnly {
		params.Set("ifGenerationMatch", "0")
	}
	u := g.uploadBase + url.PathEscape(bucket) + "/o?" + params.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	contentType := opts.ContentType
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := g.client.Do(req)
	if err != nil {
		// The error carries the URL (bucket and object only, no token).
		return fmt.Errorf("analytics: upload: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusPreconditionFailed:
		if opts.CreateOnly {
			return nil
		}
		return fmt.Errorf("analytics: upload: status %d", resp.StatusCode)
	default:
		return fmt.Errorf("analytics: upload: status %d", resp.StatusCode)
	}
}

package photo

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// fetchTimeout bounds a LinkedIn picture download.
const fetchTimeout = 5 * time.Second

// Fetcher downloads a LinkedIn profile picture, once, server-side (plan
// 2.1). The address comes from a third party, so it is treated as untrusted:
// https only, a host ending in .licdn.com, every redirect held to the same
// rule, and a time and size cap. Nothing else can be reached through it.
type Fetcher struct {
	client *http.Client
	// allowed reports whether a URL may be fetched. A field so a test can
	// point it at a local server.
	allowed func(*url.URL) bool
}

// NewFetcher constructs the Fetcher production uses.
func NewFetcher() *Fetcher { return newFetcher(linkedInPicture, nil) }

func newFetcher(allowed func(*url.URL) bool, transport http.RoundTripper) *Fetcher {
	return &Fetcher{
		allowed: allowed,
		client: &http.Client{
			Timeout:   fetchTimeout,
			Transport: transport,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 3 || !allowed(req.URL) {
					return ErrUnsafeSource
				}
				return nil
			},
		},
	}
}

func linkedInPicture(u *url.URL) bool {
	return u.Scheme == "https" && strings.HasSuffix(strings.ToLower(u.Hostname()), ".licdn.com")
}

// Fetch downloads the picture and returns the stored JPEG, its dimensions
// and etag.
func (f *Fetcher) Fetch(ctx context.Context, rawURL string) (jpegBytes []byte, w, h int, err error) {
	u, err := url.Parse(rawURL)
	if err != nil || !f.allowed(u) {
		return nil, 0, 0, ErrUnsafeSource
	}
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, 0, 0, ErrUnsafeSource
	}
	resp, err := f.client.Do(req)
	if err != nil {
		// A *url.Error's text holds the address, which is a personal one.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, 0, 0, fmt.Errorf("photo: fetch: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, 0, 0, fmt.Errorf("photo: fetch: status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, MaxFetchedBytes+1))
	if err != nil {
		return nil, 0, 0, errors.New("photo: fetch: read")
	}
	return NormalizeFetched(raw)
}

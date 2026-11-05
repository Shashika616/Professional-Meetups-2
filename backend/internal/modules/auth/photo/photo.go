// Package photo turns an uploaded picture into the one small JPEG the app
// keeps for a user (plan 2.1, decision D3). Pure Go, no cgo: the stored image
// is always a fresh encode, so nothing from the upload survives but pixels.
// That is what strips EXIF, including GPS.
package photo

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"net/http"

	"golang.org/x/image/draw"
	"golang.org/x/image/webp"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

const (
	// MaxUploadBytes is the largest picture a user may upload. The app crops
	// and compresses on the phone, so a real upload is far below this.
	MaxUploadBytes = 300 << 10
	// MaxFetchedBytes is the largest picture fetched from LinkedIn.
	MaxFetchedBytes = 2 << 20
	// MaxSide bounds the dimensions read from the header, before any pixel
	// is decoded, so a small file declaring a huge image cannot exhaust
	// memory. The app sends 640 px, and 16-bit RGBA at this size is 32 MB.
	MaxSide = 2048
	// maxDecoding is how many pictures may be decoded at once. The server
	// that decodes them also sends SOS alerts, so a burst of uploads waits
	// its turn rather than filling memory.
	maxDecoding = 2
	// Side is the stored size: the largest avatar is 96 pt at 3x.
	Side = 320
	// MaxStoredBytes matches the CHECK on auth.user_photos.
	MaxStoredBytes = 102400

	jpegQuality = 80
	// fallbackQuality is for the rare noisy picture that does not fit.
	fallbackQuality = 55
)

var decoding = make(chan struct{}, maxDecoding)

// ErrNotAnImage is the one refusal a user sees for any unusable picture.
var ErrNotAnImage = fmt.Errorf("photo: use a JPEG, PNG or WebP picture: %w", apperror.ErrInvalidInput)

// ErrUnsafeSource is a LinkedIn picture address outside licdn.com.
var ErrUnsafeSource = errors.New("photo: not a LinkedIn picture address")

// ErrTooLarge is a picture over the size allowed.
var ErrTooLarge = fmt.Errorf("photo: that picture is too large: %w", apperror.ErrInvalidInput)

// Normalize makes the stored JPEG from an upload.
func Normalize(raw []byte) (out []byte, w, h int, err error) {
	return normalize(raw, MaxUploadBytes)
}

// NormalizeFetched is Normalize for a picture fetched from LinkedIn, whose
// originals are larger than anything the app uploads.
func NormalizeFetched(raw []byte) (out []byte, w, h int, err error) {
	return normalize(raw, MaxFetchedBytes)
}

func normalize(raw []byte, maxBytes int) ([]byte, int, int, error) {
	if len(raw) > maxBytes {
		return nil, 0, 0, ErrTooLarge
	}
	var decodeConfig func(*bytes.Reader) (image.Config, error)
	var decode func(*bytes.Reader) (image.Image, error)
	// By content, never by a name or a Content-Type the client chose.
	switch http.DetectContentType(raw) {
	case "image/jpeg":
		decodeConfig = func(r *bytes.Reader) (image.Config, error) { return jpeg.DecodeConfig(r) }
		decode = func(r *bytes.Reader) (image.Image, error) { return jpeg.Decode(r) }
	case "image/png":
		decodeConfig = func(r *bytes.Reader) (image.Config, error) { return png.DecodeConfig(r) }
		decode = func(r *bytes.Reader) (image.Image, error) { return png.Decode(r) }
	case "image/webp":
		decodeConfig = func(r *bytes.Reader) (image.Config, error) { return webp.DecodeConfig(r) }
		decode = func(r *bytes.Reader) (image.Image, error) { return webp.Decode(r) }
	default:
		return nil, 0, 0, ErrNotAnImage
	}

	cfg, err := decodeConfig(bytes.NewReader(raw))
	if err != nil {
		return nil, 0, 0, ErrNotAnImage
	}
	if cfg.Width < 1 || cfg.Height < 1 || cfg.Width > MaxSide || cfg.Height > MaxSide {
		return nil, 0, 0, ErrTooLarge
	}
	decoding <- struct{}{}
	defer func() { <-decoding }()
	src, err := decode(bytes.NewReader(raw))
	if err != nil {
		return nil, 0, 0, ErrNotAnImage
	}

	dst := image.NewRGBA(image.Rect(0, 0, Side, Side))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, centreSquare(src.Bounds()), draw.Src, nil)

	for _, quality := range []int{jpegQuality, fallbackQuality} {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: quality}); err != nil {
			return nil, 0, 0, fmt.Errorf("photo: encode: %w", err)
		}
		if buf.Len() <= MaxStoredBytes {
			return buf.Bytes(), Side, Side, nil
		}
	}
	return nil, 0, 0, ErrTooLarge
}

// centreSquare is the largest centred square in b. The app has already
// cropped, so this matters only for a picture from elsewhere.
func centreSquare(b image.Rectangle) image.Rectangle {
	side := min(b.Dx(), b.Dy())
	x := b.Min.X + (b.Dx()-side)/2
	y := b.Min.Y + (b.Dy()-side)/2
	return image.Rect(x, y, x+side, y+side)
}

// Etag is the first 16 hex characters of the SHA-256 of the stored bytes.
func Etag(jpegBytes []byte) string {
	sum := sha256.Sum256(jpegBytes)
	return hex.EncodeToString(sum[:])[:16]
}

// Path is where the photo is served from. It goes in every payload that
// shows a user: a changed photo changes the URL, so no cache shows a stale
// one.
func Path(userID, etag string) string {
	return "/v1/users/" + userID + "/photo?v=" + etag
}

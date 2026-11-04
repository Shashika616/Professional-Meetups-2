package photo

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func picture(w, h int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 120, 255})
		}
	}
	return img
}

func jpegOf(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := jpeg.Encode(&b, picture(w, h), nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func pngOf(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, picture(w, h)); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// A 1x1 lossy WebP, from the format's own smallest example.
const webpBase64 = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"

func checkOutput(t *testing.T, out []byte, w, h int) {
	t.Helper()
	if w != Side || h != Side {
		t.Errorf("size %dx%d, want %dx%d", w, h, Side, Side)
	}
	if len(out) > MaxStoredBytes {
		t.Errorf("%d bytes stored", len(out))
	}
	img, err := jpeg.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatalf("the output is not a JPEG: %v", err)
	}
	if b := img.Bounds(); b.Dx() != Side || b.Dy() != Side {
		t.Errorf("decoded %v", b)
	}
}

func TestNormalizeAcceptsEachFormat(t *testing.T) {
	webpBytes, err := base64.StdEncoding.DecodeString(webpBase64)
	if err != nil {
		t.Fatal(err)
	}
	for name, raw := range map[string][]byte{
		"jpeg": jpegOf(t, 640, 640), "png": pngOf(t, 400, 400), "webp": webpBytes,
		"wide, cropped to the centre": jpegOf(t, 800, 300), "small, scaled up": jpegOf(t, 50, 50),
	} {
		t.Run(name, func(t *testing.T) {
			out, w, h, err := Normalize(raw)
			if err != nil {
				t.Fatal(err)
			}
			checkOutput(t, out, w, h)
		})
	}
}

// Content decides, not a name: a PNG called .jpg is a PNG, and a text file
// called .jpg is not a picture.
func TestNormalizeGoesByContent(t *testing.T) {
	if _, _, _, err := Normalize(pngOf(t, 64, 64)); err != nil {
		t.Errorf("a PNG sent as anything: %v", err)
	}
	for name, raw := range map[string][]byte{
		"text":           []byte("<html>not a picture</html>"),
		"empty":          {},
		"gif":            []byte("GIF89a\x01\x00\x01\x00\x00\x00\x00"),
		"svg":            []byte(`<svg xmlns="http://www.w3.org/2000/svg"/>`),
		"truncated jpeg": jpegOf(t, 64, 64)[:60],
	} {
		if _, _, _, err := Normalize(raw); !errors.Is(err, ErrNotAnImage) {
			t.Errorf("%s: %v, want not an image", name, err)
		}
	}
}

func TestNormalizeRefusesOversizedInput(t *testing.T) {
	big := append(jpegOf(t, 64, 64), make([]byte, MaxUploadBytes)...)
	if _, _, _, err := Normalize(big); !errors.Is(err, ErrTooLarge) {
		t.Errorf("301 KB: %v, want too large", err)
	}
	if _, _, _, err := NormalizeFetched(big); err != nil {
		t.Errorf("the same bytes fetched from LinkedIn: %v", err)
	}
}

// A decompression bomb: a tiny file whose header declares a huge image is
// refused from the header alone. Its width and height are patched into a
// real PNG, whose pixels are never reached.
func TestNormalizeRefusesADecompressionBomb(t *testing.T) {
	raw := pngOf(t, 8, 8)
	copy(raw[16:24], []byte{0, 1, 0, 0, 0, 1, 0, 0}) // 65536 x 65536
	binary.BigEndian.PutUint32(raw[29:33], crc32.ChecksumIEEE(raw[12:29]))
	if _, _, _, err := Normalize(raw); !errors.Is(err, ErrTooLarge) {
		t.Errorf("error = %v, want too large", err)
	}
	if _, _, _, err := Normalize(pngOf(t, MaxSide+1, 4)); !errors.Is(err, ErrTooLarge) {
		t.Errorf("one pixel over the limit: %v", err)
	}
}

// Plan 2.1: re-encoding strips EXIF, including GPS.
func TestNormalizeStripsEXIF(t *testing.T) {
	raw := jpegOf(t, 64, 64)
	marker := "Exif\x00\x00GPSLatitude 6.9271"
	segment := append([]byte{0xFF, 0xE1, 0, byte(len(marker) + 2)}, marker...)
	withExif := append(append(append([]byte{}, raw[:2]...), segment...), raw[2:]...)
	if !bytes.Contains(withExif, []byte("GPSLatitude")) {
		t.Fatal("the test picture has no EXIF")
	}
	out, _, _, err := Normalize(withExif)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out, []byte("Exif")) || bytes.Contains(out, []byte("GPSLatitude")) {
		t.Error("EXIF survived")
	}
}

func TestEtagAndPath(t *testing.T) {
	e := Etag([]byte("x"))
	if len(e) != 16 || e != Etag([]byte("x")) || e == Etag([]byte("y")) {
		t.Errorf("etag %q", e)
	}
	if got := Path("u1", "abc"); got != "/v1/users/u1/photo?v=abc" {
		t.Errorf("path %q", got)
	}
}

// Plan 2.1: the SSRF guard.
func TestFetchOnlyGoesToLinkedIn(t *testing.T) {
	f := NewFetcher()
	for _, bad := range []string{
		"http://media.licdn.com/a.jpg",
		"https://evil.example/a.jpg",
		"https://licdn.com.evil.example/a.jpg",
		"https://evillicdn.com/a.jpg",
		"https://169.254.169.254/latest/meta-data",
		"file:///etc/passwd",
		"not a url",
	} {
		if _, _, _, err := f.Fetch(context.Background(), bad); !errors.Is(err, ErrUnsafeSource) {
			t.Errorf("%s: %v, want refused", bad, err)
		}
	}
}

func TestFetchHoldsRedirectsToTheSameRule(t *testing.T) {
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("the redirect was followed to another host")
		_, _ = w.Write(jpegOf(t, 64, 64))
	}))
	defer other.Close()
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/a.jpg", http.StatusFound)
	}))
	defer first.Close()
	onlyFirst := func(u *url.URL) bool { return u.Host == strings.TrimPrefix(first.URL, "http://") }
	f := newFetcher(onlyFirst, nil)
	if _, _, _, err := f.Fetch(context.Background(), first.URL+"/a.jpg"); !errors.Is(err, ErrUnsafeSource) {
		t.Errorf("error = %v, want refused", err)
	}
}

func TestFetchNormalizesAndCaps(t *testing.T) {
	pic := jpegOf(t, 400, 400)
	huge := make([]byte, MaxFetchedBytes+10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/huge" {
			_, _ = w.Write(huge)
			return
		}
		_, _ = w.Write(pic)
	}))
	defer srv.Close()
	f := newFetcher(func(*url.URL) bool { return true }, nil)
	out, w, h, err := f.Fetch(context.Background(), srv.URL+"/a.jpg")
	if err != nil {
		t.Fatal(err)
	}
	checkOutput(t, out, w, h)
	if _, _, _, err := f.Fetch(context.Background(), srv.URL+"/huge"); err == nil {
		t.Error("a body past the cap was accepted")
	}
	if fetchTimeout != 5*time.Second {
		t.Errorf("timeout %v", fetchTimeout)
	}
}

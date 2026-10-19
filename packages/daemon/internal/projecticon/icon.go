// Package projecticon stores and reads small images through a confined project root.
package projecticon

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"os"
	"path"
	"strings"
)

const Version = 2
const MaxBytes = 1 << 20

var ErrInvalid = errors.New("invalid project icon")

type Image struct {
	Path      string `json:"path"`
	MediaType string `json:"mediaType"`
	Content   []byte `json:"content"` // JSON base64; never a public file URL.
	ETag      string `json:"etag"`
}

func invalid(message string) error { return fmt.Errorf("%w: %s", ErrInvalid, message) }

func ValidatePath(name string) error {
	if name == "" || len(name) > 4096 || strings.HasPrefix(name, "/") || strings.ContainsAny(name, "\\\x00") {
		return invalid("choose an image inside the project")
	}
	for _, part := range strings.Split(name, "/") {
		if part == "" || part == "." || part == ".." || strings.EqualFold(part, ".git") {
			return invalid("choose an image inside the project")
		}
	}
	switch strings.ToLower(path.Ext(name)) {
	case ".svg", ".png", ".jpg", ".jpeg", ".gif":
		return nil
	default:
		return invalid("choose an SVG, PNG, JPEG or GIF image")
	}
}

func Read(directory, name string) (Image, error) {
	if err := ValidatePath(name); err != nil {
		return Image{}, err
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return Image{}, invalid("the project folder is unavailable")
	}
	defer root.Close()
	info, err := root.Stat(name)
	if err != nil || !info.Mode().IsRegular() {
		return Image{}, invalid("the icon must be a file inside the project")
	}
	if info.Size() > MaxBytes {
		return Image{}, invalid("choose an image smaller than 1 MB")
	}
	// os.Root follows internal symlinks while rejecting escapes, including a path
	// changed between selection and reading. Never read via a client-supplied URL.
	file, err := root.Open(name)
	if err != nil {
		return Image{}, invalid("the icon could not be opened")
	}
	defer file.Close()
	info, err = file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return Image{}, invalid("the icon must be a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, MaxBytes+1))
	if err != nil {
		return Image{}, invalid("the icon could not be read")
	}
	return validate(name, data)
}

func validate(name string, data []byte) (Image, error) {
	if len(data) == 0 || len(data) > MaxBytes {
		return Image{}, invalid("choose an image smaller than 1 MB")
	}
	mediaType := ""
	if strings.EqualFold(path.Ext(name), ".svg") {
		if err := validateSVG(data); err != nil {
			return Image{}, err
		}
		mediaType = "image/svg+xml"
	} else {
		config, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > 8192 || config.Height > 8192 ||
			int64(config.Width)*int64(config.Height) > 32_000_000 {
			return Image{}, invalid("choose a valid image no larger than 8192 pixels")
		}
		mediaType = "image/" + format
	}
	hash := sha256.Sum256(data)
	return Image{Path: name, MediaType: mediaType, Content: data, ETag: hex.EncodeToString(hash[:])}, nil
}

// Upload never uses a client-supplied storage path. Identical images reuse the
// same content-addressed file; a temporary file makes publication atomic.
// The caller saves the returned path through the usual revisioned project edit.
func Upload(directory, name string, data []byte) (Image, error) {
	ext := strings.ToLower(path.Ext(name))
	if err := ValidatePath("icon" + ext); err != nil {
		return Image{}, err
	}
	icon, err := validate("icon"+ext, data)
	if err != nil {
		return Image{}, err
	}
	const folder = ".mindwire/project-icons"
	icon.Path = folder + "/" + icon.ETag + ext
	root, err := os.OpenRoot(directory)
	if err != nil {
		return Image{}, invalid("the project folder is unavailable")
	}
	defer root.Close()
	if err = root.MkdirAll(folder, 0700); err != nil {
		return Image{}, invalid("the icon folder could not be created")
	}
	var nonce [16]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return Image{}, err
	}
	temporary := folder + "/.upload-" + hex.EncodeToString(nonce[:])
	file, err := root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return Image{}, invalid("the icon could not be uploaded")
	}
	defer root.Remove(temporary)
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		return Image{}, invalid("the icon could not be uploaded")
	}
	if err = root.Rename(temporary, icon.Path); err != nil {
		return Image{}, invalid("the icon could not be uploaded")
	}
	return icon, nil
}

func validateSVG(data []byte) error {
	d := xml.NewDecoder(bytes.NewReader(data))
	depth, nodes, roots := 0, 0, 0
	for {
		token, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return invalid("the SVG could not be read")
		}
		switch v := token.(type) {
		case xml.Directive:
			return invalid("SVG declarations with external resources are not supported")
		case xml.ProcInst:
			if v.Target != "xml" {
				return invalid("SVG processing instructions are not supported")
			}
		case xml.StartElement:
			if depth == 0 {
				roots++
				if v.Name.Local != "svg" || roots != 1 {
					return invalid("choose a valid SVG image")
				}
			}
			depth++
			nodes++
			if depth > 64 || nodes > 10_000 {
				return invalid("this SVG is too complex for a project icon")
			}
			switch strings.ToLower(v.Name.Local) {
			case "script", "foreignobject", "image":
				return invalid("use a self-contained SVG without scripts or embedded images")
			}
			for _, attr := range v.Attr {
				if strings.EqualFold(attr.Name.Local, "href") && !strings.HasPrefix(attr.Value, "#") {
					return invalid("use a self-contained SVG without external links")
				}
			}
		case xml.EndElement:
			depth--
		}
	}
	if roots != 1 || depth != 0 {
		return invalid("choose a valid SVG image")
	}
	return nil
}

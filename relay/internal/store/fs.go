package store

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// FS keeps objects as files under a root directory: development, tests,
// and a single box that has no bucket yet.
type FS struct{ Root string }

func (f *FS) path(key string) string { return filepath.Join(f.Root, filepath.FromSlash(key)) }

func (f *FS) Put(_ context.Context, key string, r io.Reader, _ int64) error {
	p := f.path(key)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	// Write then rename: a torn upload never leaves a half object.
	tmp := p + ".tmp"
	w, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(w, r); err != nil {
		w.Close()
		os.Remove(tmp)
		return err
	}
	if err := w.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, p)
}

func (f *FS) Get(_ context.Context, key string) (io.ReadCloser, int64, error) {
	st, err := os.Stat(f.path(key))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, 0, ErrNotFound
		}
		return nil, 0, err
	}
	r, err := os.Open(f.path(key))
	if err != nil {
		return nil, 0, err
	}
	return r, st.Size(), nil
}

func (f *FS) Head(_ context.Context, key string) (bool, error) {
	_, err := os.Stat(f.path(key))
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
}

func (f *FS) List(_ context.Context, prefix string) ([]string, error) {
	var out []string
	root := f.Root
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if d.IsDir() || strings.HasSuffix(p, ".tmp") {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		key := filepath.ToSlash(rel)
		if strings.HasPrefix(key, prefix) {
			out = append(out, key)
		}
		return nil
	})
	if out == nil {
		out = []string{}
	}
	return out, err
}

func (f *FS) Delete(_ context.Context, key string) error {
	err := os.Remove(f.path(key))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

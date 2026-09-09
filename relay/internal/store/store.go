// Package store is the relay's object store: the sealed batches and blobs
// a property's devices exchange (docs/RELAY-DESIGN.md). The relay never
// looks inside an object.
package store

import (
	"context"
	"errors"
	"io"
)

// ErrNotFound is returned by Get and Head for a missing object.
var ErrNotFound = errors.New("object not found")

// ObjectStore holds bytes under string keys. Keys are "<property>/<path>".
type ObjectStore interface {
	Put(ctx context.Context, key string, r io.Reader, size int64) error
	Get(ctx context.Context, key string) (io.ReadCloser, int64, error)
	Head(ctx context.Context, key string) (bool, error)
	List(ctx context.Context, prefix string) ([]string, error)
	Delete(ctx context.Context, key string) error
}

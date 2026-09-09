// The Field Notes relay (D-031): one binary, SQLite for who is in a
// property, a directory or an S3 bucket for the sealed bytes they exchange.
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"fieldnotes/relay/internal/api"
	"fieldnotes/relay/internal/control"
	"fieldnotes/relay/internal/store"
)

func main() {
	addr := flag.String("addr", envOr("RELAY_ADDR", ":8080"), "listen address")
	dbPath := flag.String("db", envOr("RELAY_DB", "relay.sqlite"), "control-plane SQLite file")
	storeURL := flag.String("store", envOr("RELAY_STORE", "dir:./relay-store"), "dir:/path or s3://bucket/prefix")
	pubKey := flag.String("license-pubkey", os.Getenv("RELAY_LICENSE_PUBKEY"), "base64 ed25519 public key for organization keys")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	db, err := control.Open(*dbPath)
	if err != nil {
		log.Error("open db", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	var st store.ObjectStore
	switch {
	case strings.HasPrefix(*storeURL, "dir:"):
		st = &store.FS{Root: strings.TrimPrefix(*storeURL, "dir:")}
	case strings.HasPrefix(*storeURL, "s3://"):
		rest := strings.TrimPrefix(*storeURL, "s3://")
		bucket, prefix, _ := strings.Cut(rest, "/")
		if prefix != "" && !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
		cfg, err := awsconfig.LoadDefaultConfig(context.Background())
		if err != nil {
			log.Error("aws config", "err", err)
			os.Exit(1)
		}
		st = &store.S3{Client: s3.NewFromConfig(cfg), Bucket: bucket, Prefix: prefix}
	default:
		log.Error("store must be dir:/path or s3://bucket/prefix")
		os.Exit(1)
	}

	var pub ed25519.PublicKey
	if *pubKey != "" {
		b, err := base64.StdEncoding.DecodeString(*pubKey)
		if err != nil || len(b) != ed25519.PublicKeySize {
			log.Error("license pubkey must be a base64 32-byte ed25519 key")
			os.Exit(1)
		}
		pub = ed25519.PublicKey(b)
	}

	srv := &api.Server{DB: db, Store: st, PubKey: pub, Log: log}
	h := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute,
		WriteTimeout:      5 * time.Minute,
	}
	log.Info("relay listening", "addr", *addr, "store", *storeURL, "licenses", pub != nil)
	if err := h.ListenAndServe(); err != nil {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

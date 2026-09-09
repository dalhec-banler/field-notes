// issue-license signs an organization key (D-030) with the private key
// kept outside the repo. `-gen` makes a keypair once; the public half goes
// into the relay's flag and the app.
//
//	issue-license -gen -key ~/.keystores/fieldnotes-license.key
//	issue-license -key ~/.keystores/fieldnotes-license.key \
//	  -org "Plateau Land & Wildlife" -seats 10 -badge Plateau -years 1
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"fieldnotes/relay/internal/license"
)

func main() {
	keyPath := flag.String("key", "", "private key file (base64 ed25519 seed)")
	gen := flag.Bool("gen", false, "generate a keypair into -key and print the public key")
	org := flag.String("org", "", "organization name")
	seats := flag.Int("seats", 0, "seats")
	badge := flag.String("badge", "", "badge name (defaults to org)")
	mark := flag.String("mark", "", "path to a small PNG for the badge mark (optional)")
	years := flag.Float64("years", 1, "validity in years; 0 = never expires")
	id := flag.String("id", "", "licence id (defaults to a random one)")
	flag.Parse()
	if *keyPath == "" {
		fail("-key is required")
	}
	if *gen {
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		if err := os.WriteFile(*keyPath, []byte(base64.StdEncoding.EncodeToString(priv.Seed())), 0o600); err != nil {
			fail(err.Error())
		}
		fmt.Println("public key:", base64.StdEncoding.EncodeToString(pub))
		return
	}
	raw, err := os.ReadFile(*keyPath)
	if err != nil {
		fail(err.Error())
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		fail("the key file is not a base64 ed25519 seed")
	}
	priv := ed25519.NewKeyFromSeed(seed)
	if *org == "" || *seats <= 0 {
		fail("-org and -seats are required")
	}
	if *id == "" {
		b := make([]byte, 8)
		rand.Read(b)
		*id = "org-" + hex.EncodeToString(b)
	}
	p := license.Payload{ID: *id, Org: *org, Seats: *seats, Badge: license.Badge{Name: *badge}, IssuedAt: time.Now().UTC().Format(time.RFC3339)}
	if p.Badge.Name == "" {
		p.Badge.Name = *org
	}
	if *mark != "" {
		png, err := os.ReadFile(*mark)
		if err != nil {
			fail(err.Error())
		}
		if len(png) > 64<<10 {
			fail("the mark should be under 64 KB")
		}
		p.Badge.Mark = base64.StdEncoding.EncodeToString(png)
	}
	if *years > 0 {
		p.ExpiresAt = time.Now().UTC().Add(time.Duration(*years * 365 * 24 * float64(time.Hour))).Format(time.RFC3339)
	}
	key, err := license.Sign(priv, p)
	if err != nil {
		fail(err.Error())
	}
	fmt.Println(key)
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(2)
}

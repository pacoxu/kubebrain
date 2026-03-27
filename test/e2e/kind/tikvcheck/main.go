// Copyright 2022 ByteDance and/or its affiliates
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"os"
	"path"
	"strings"
	"time"

	tikverr "github.com/tikv/client-go/v2/error"
	"github.com/tikv/client-go/v2/txnkv"
)

var (
	magicBytes = []byte{0x57, 0xfb, 0x80, 0x8b}
	splitByte  = byte('$')
)

type options struct {
	pdAddrs       string
	namespace     string
	podName       string
	expectedImage string
	keyPrefix     string
	timeout       time.Duration
	retryInterval time.Duration
}

func parseFlags() (*options, error) {
	opt := &options{}
	flag.StringVar(&opt.pdAddrs, "pd-addrs", "", "comma-separated PD addresses")
	flag.StringVar(&opt.namespace, "namespace", "", "pod namespace")
	flag.StringVar(&opt.podName, "pod-name", "", "pod name")
	flag.StringVar(&opt.expectedImage, "expected-image", "", "expected pod image in stored value")
	flag.StringVar(&opt.keyPrefix, "key-prefix", "", "optional key prefix used by kube-brain")
	flag.DurationVar(&opt.timeout, "timeout", 90*time.Second, "max time to wait for Pod object in TiKV")
	flag.DurationVar(&opt.retryInterval, "retry-interval", time.Second, "retry interval when key is not ready")
	flag.Parse()

	if strings.TrimSpace(opt.pdAddrs) == "" {
		return nil, errors.New("missing --pd-addrs")
	}
	if strings.TrimSpace(opt.namespace) == "" {
		return nil, errors.New("missing --namespace")
	}
	if strings.TrimSpace(opt.podName) == "" {
		return nil, errors.New("missing --pod-name")
	}
	if opt.timeout <= 0 {
		return nil, fmt.Errorf("invalid --timeout=%s", opt.timeout)
	}
	if opt.retryInterval <= 0 {
		return nil, fmt.Errorf("invalid --retry-interval=%s", opt.retryInterval)
	}
	return opt, nil
}

func splitPDAddrs(input string) []string {
	parts := strings.Split(input, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		result = append(result, p)
	}
	return result
}

func encodeObjectKey(userKey []byte, revision uint64) []byte {
	key := make([]byte, len(magicBytes)+len(userKey)+1+8)
	copy(key, magicBytes)
	copy(key[len(magicBytes):], userKey)
	key[len(magicBytes)+len(userKey)] = splitByte
	binary.BigEndian.PutUint64(key[len(magicBytes)+len(userKey)+1:], revision)
	return key
}

func buildRawKeyCandidates(prefix string, namespace string, podName string) []string {
	base := path.Join("/registry/pods", namespace, podName)
	candidates := []string{base}

	normalized := strings.TrimSpace(prefix)
	if normalized != "" && normalized != "/" {
		if !strings.HasPrefix(normalized, "/") {
			normalized = "/" + normalized
		}
		normalized = strings.TrimSuffix(normalized, "/")
		candidates = append(candidates, path.Join(normalized, "registry", "pods", namespace, podName))
	}

	uniq := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, key := range candidates {
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		uniq = append(uniq, key)
	}
	return uniq
}

func readValue(ctx context.Context, client *txnkv.Client, key []byte) ([]byte, error) {
	ts, err := client.GetTimestamp(ctx)
	if err != nil {
		return nil, fmt.Errorf("get timestamp: %w", err)
	}
	snapshot := client.GetSnapshot(ts)
	value, err := snapshot.Get(ctx, key)
	if err != nil {
		if tikverr.IsErrNotFound(err) {
			return nil, err
		}
		return nil, fmt.Errorf("snapshot get key %x: %w", key, err)
	}
	return value, nil
}

func verifyRawPodKey(ctx context.Context, client *txnkv.Client, rawKey string, expectedImage string) error {
	revisionKey := encodeObjectKey([]byte(rawKey), 0)
	revisionValue, err := readValue(ctx, client, revisionKey)
	if err != nil {
		if tikverr.IsErrNotFound(err) {
			return fmt.Errorf("revision key not found for raw key %q", rawKey)
		}
		return err
	}
	if len(revisionValue) < 8 {
		return fmt.Errorf("invalid revision value length=%d for raw key %q", len(revisionValue), rawKey)
	}
	if len(revisionValue) == 9 {
		return fmt.Errorf("raw key %q is tombstoned at revision=%d", rawKey, binary.BigEndian.Uint64(revisionValue[:8]))
	}
	if len(revisionValue) != 8 {
		return fmt.Errorf("unexpected revision value length=%d for raw key %q", len(revisionValue), rawKey)
	}

	revision := binary.BigEndian.Uint64(revisionValue[:8])
	objectKey := encodeObjectKey([]byte(rawKey), revision)
	objectValue, err := readValue(ctx, client, objectKey)
	if err != nil {
		if tikverr.IsErrNotFound(err) {
			return fmt.Errorf("object key not found for raw key %q at revision=%d", rawKey, revision)
		}
		return err
	}

	if len(objectValue) == 0 {
		return fmt.Errorf("empty object value for raw key %q at revision=%d", rawKey, revision)
	}
	if expectedImage != "" && !bytes.Contains(objectValue, []byte(expectedImage)) {
		return fmt.Errorf("object value for raw key %q does not contain expected image %q", rawKey, expectedImage)
	}

	parts := strings.Split(strings.Trim(rawKey, "/"), "/")
	if len(parts) < 2 {
		return fmt.Errorf("invalid raw key %q", rawKey)
	}
	ns := parts[len(parts)-2]
	name := parts[len(parts)-1]
	if !bytes.Contains(objectValue, []byte(ns)) {
		return fmt.Errorf("object value for raw key %q does not contain namespace %q", rawKey, ns)
	}
	if !bytes.Contains(objectValue, []byte(name)) {
		return fmt.Errorf("object value for raw key %q does not contain pod name %q", rawKey, name)
	}

	fmt.Printf("verified pod key in TiKV: rawKey=%s revision=%d size=%d\n", rawKey, revision, len(objectValue))
	return nil
}

func run(opt *options) error {
	pdAddrs := splitPDAddrs(opt.pdAddrs)
	if len(pdAddrs) == 0 {
		return errors.New("no valid PD addresses from --pd-addrs")
	}

	client, err := txnkv.NewClient(pdAddrs)
	if err != nil {
		return fmt.Errorf("create TiKV client: %w", err)
	}
	defer func() { _ = client.Close() }()

	keys := buildRawKeyCandidates(opt.keyPrefix, opt.namespace, opt.podName)
	deadline := time.Now().Add(opt.timeout)
	var lastErr error
	for {
		for _, rawKey := range keys {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := verifyRawPodKey(ctx, client, rawKey, opt.expectedImage)
			cancel()
			if err == nil {
				return nil
			}
			lastErr = err
		}

		if time.Now().After(deadline) {
			break
		}
		time.Sleep(opt.retryInterval)
	}
	return fmt.Errorf("failed to verify pod key from TiKV after %s: %w", opt.timeout, lastErr)
}

func main() {
	opt, err := parseFlags()
	if err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "invalid flags: %v\n", err)
		os.Exit(1)
	}
	if err := run(opt); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "tikv pod verification failed: %v\n", err)
		os.Exit(1)
	}
}

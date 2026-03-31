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
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	proto "github.com/kubewharf/kubebrain-client/api/v2rpc"
	"go.etcd.io/etcd/client/v3"
	"google.golang.org/grpc"

	"github.com/kubewharf/kubebrain/test/jepsen/history"
)

func main() {
	var (
		endpointsArg       = flag.String("endpoints", "127.0.0.1:2379", "comma-separated etcd/kubebrain endpoints")
		duration           = flag.Duration("duration", 2*time.Minute, "workload duration")
		workers            = flag.Int("workers", 16, "number of concurrent workers")
		keys               = flag.Int("keys", 64, "number of keys in keyspace")
		keyPrefix          = flag.String("key-prefix", "/jepsen/kubebrain/", "key prefix for workload")
		timeout            = flag.Duration("timeout", 3*time.Second, "per-operation timeout")
		outPath            = flag.String("out", "test/jepsen/artifacts/history.jsonl", "history output JSONL path")
		seed               = flag.Int64("seed", 0, "random seed, 0 means auto")
		opsPerWorker       = flag.Int("ops-per-worker", 0, "stop each worker after N ops, 0 means unlimited")
		compactInterval    = flag.Duration("compact-interval", 30*time.Second, "interval for compact requests, 0 disables compact")
		compactRevisionLag = flag.Uint64("compact-revision-lag", 100, "compact target is max_observed_revision - lag")
	)
	flag.Parse()

	if *workers <= 0 {
		exitf("workers must be greater than 0")
	}
	if *keys <= 0 {
		exitf("keys must be greater than 0")
	}
	if *duration <= 0 && *opsPerWorker <= 0 {
		exitf("duration must be greater than 0 when ops-per-worker is 0")
	}
	if *timeout <= 0 {
		exitf("timeout must be greater than 0")
	}

	endpoints := splitNonEmpty(*endpointsArg)
	if len(endpoints) == 0 {
		exitf("at least one endpoint is required")
	}

	if *seed == 0 {
		*seed = time.Now().UnixNano()
	}
	fmt.Printf("jepsen harness seed=%d endpoints=%v workers=%d keys=%d\n", *seed, endpoints, *workers, *keys)

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: *timeout,
	})
	if err != nil {
		exitf("create etcd client failed: %v", err)
	}
	defer cli.Close()

	grpcCtx, grpcCancel := context.WithTimeout(context.Background(), *timeout)
	conn, err := grpc.DialContext(grpcCtx, endpoints[0], grpc.WithInsecure(), grpc.WithBlock())
	grpcCancel()
	if err != nil {
		exitf("create grpc connection for compact failed: %v", err)
	}
	defer conn.Close()
	writeClient := proto.NewWriteClient(conn)

	if err := os.MkdirAll(filepath.Dir(*outPath), 0755); err != nil {
		exitf("create output directory failed: %v", err)
	}

	recordCh := make(chan history.Record, 2048)
	writeErrCh := make(chan error, 1)
	go func() {
		writeErrCh <- writeJSONL(*outPath, recordCh)
	}()

	var (
		recordID    int64
		maxRevision int64
		workerWG    sync.WaitGroup
		compactorWG sync.WaitGroup
		ctx         context.Context
		cancel      context.CancelFunc
	)

	if *opsPerWorker > 0 {
		ctx, cancel = context.WithCancel(context.Background())
	} else {
		ctx, cancel = context.WithTimeout(context.Background(), *duration)
	}
	defer cancel()

	keyList := make([]string, 0, *keys)
	for i := 0; i < *keys; i++ {
		keyList = append(keyList, fmt.Sprintf("%skey-%05d", *keyPrefix, i))
	}

	start := time.Now()
	for workerID := 0; workerID < *workers; workerID++ {
		workerWG.Add(1)
		go func(workerID int) {
			defer workerWG.Done()
			runWorker(ctx, workerID, *seed+int64(workerID)*10007, *timeout, *opsPerWorker, keyList, cli, recordCh, &recordID, &maxRevision)
		}(workerID)
	}

	if *compactInterval > 0 {
		compactorWG.Add(1)
		go func() {
			defer compactorWG.Done()
			runCompactor(ctx, *compactInterval, *timeout, int64(*compactRevisionLag), writeClient, recordCh, &recordID, &maxRevision)
		}()
	}

	workerWG.Wait()
	cancel()
	compactorWG.Wait()
	close(recordCh)

	if err := <-writeErrCh; err != nil {
		exitf("write history failed: %v", err)
	}

	elapsed := time.Since(start)
	fmt.Printf("jepsen harness done history=%s elapsed=%s max_revision=%d\n", *outPath, elapsed, atomic.LoadInt64(&maxRevision))
}

func runWorker(
	ctx context.Context,
	workerID int,
	seed int64,
	timeout time.Duration,
	opsLimit int,
	keys []string,
	cli *clientv3.Client,
	out chan<- history.Record,
	idCounter *int64,
	maxRevision *int64,
) {
	rng := rand.New(rand.NewSource(seed))

	opsDone := 0
	for {
		if opsLimit > 0 && opsDone >= opsLimit {
			return
		}
		select {
		case <-ctx.Done():
			return
		default:
		}

		op := chooseOperation(rng.Intn(100))
		key := keys[rng.Intn(len(keys))]
		value := fmt.Sprintf("client-%d-op-%d-%d", workerID, opsDone, time.Now().UnixNano())
		invoke := time.Now().UnixNano()

		rec := history.Record{
			ID:             atomic.AddInt64(idCounter, 1),
			ClientID:       workerID,
			Operation:      op,
			Key:            key,
			RequestValue:   value,
			InvokeUnixNano: invoke,
		}

		opCtx, cancel := context.WithTimeout(ctx, timeout)
		switch op {
		case history.OpCreate:
			rec.ExpectedModRevision = 0
			succeeded, respRev, modRev, err := runCreate(opCtx, cli, key, value)
			rec.Succeeded = succeeded
			rec.ResponseRevision = respRev
			rec.ResponseModRevision = modRev
			if err != nil {
				rec.TransportError = err.Error()
			}
		case history.OpUpdate:
			found, _, expectedRev, headerRev, err := readCurrent(opCtx, cli, key)
			if err != nil {
				rec.TransportError = err.Error()
				rec.ResponseRevision = headerRev
				break
			}
			rec.ExpectedModRevision = expectedRev
			succeeded, respRev, modRev, runErr := runUpdate(opCtx, cli, key, value, expectedRev)
			rec.Succeeded = succeeded
			rec.ResponseRevision = respRev
			rec.ResponseModRevision = modRev
			if runErr != nil {
				rec.TransportError = runErr.Error()
			}
			if !found && succeeded {
				rec.Note = "update behaved as create due to missing key"
			}
		case history.OpDelete:
			found, _, expectedRev, headerRev, err := readCurrent(opCtx, cli, key)
			if err != nil {
				rec.TransportError = err.Error()
				rec.ResponseRevision = headerRev
				break
			}
			rec.ExpectedModRevision = expectedRev
			if !found {
				rec.Succeeded = false
				rec.ResponseRevision = headerRev
				rec.Note = "key missing in pre-read"
				break
			}
			succeeded, respRev, modRev, runErr := runDelete(opCtx, cli, key, expectedRev)
			rec.Succeeded = succeeded
			rec.ResponseRevision = respRev
			rec.ResponseModRevision = modRev
			if runErr != nil {
				rec.TransportError = runErr.Error()
			}
		case history.OpGet:
			found, val, modRev, respRev, err := readCurrent(opCtx, cli, key)
			rec.Succeeded = err == nil
			rec.KeyFound = found
			rec.ResponseValue = val
			rec.ResponseModRevision = modRev
			rec.ResponseRevision = respRev
			if err != nil {
				rec.TransportError = err.Error()
			}
		}
		cancel()

		rec.FinishUnixNano = time.Now().UnixNano()
		updateMaxRevision(maxRevision, rec.ResponseRevision)
		out <- rec
		opsDone++
	}
}

func runCompactor(
	ctx context.Context,
	interval time.Duration,
	timeout time.Duration,
	revisionLag int64,
	client proto.WriteClient,
	out chan<- history.Record,
	idCounter *int64,
	maxRevision *int64,
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		maxRev := atomic.LoadInt64(maxRevision)
		target := maxRev - revisionLag
		if target < 0 {
			target = 0
		}

		invoke := time.Now().UnixNano()
		rec := history.Record{
			ID:              atomic.AddInt64(idCounter, 1),
			ClientID:        -1,
			Operation:       history.OpCompact,
			CompactRevision: target,
			InvokeUnixNano:  invoke,
		}

		opCtx, cancel := context.WithTimeout(ctx, timeout)
		resp, err := client.Compact(opCtx, &proto.CompactRequest{Revision: uint64(target)})
		cancel()
		if err != nil {
			rec.TransportError = err.Error()
			rec.Succeeded = false
		} else {
			rec.Succeeded = true
			if resp != nil && resp.GetHeader() != nil {
				rec.ResponseRevision = int64(resp.GetHeader().GetRevision())
			}
		}
		rec.FinishUnixNano = time.Now().UnixNano()
		updateMaxRevision(maxRevision, rec.ResponseRevision)
		out <- rec
	}
}

func chooseOperation(pick int) history.Operation {
	switch {
	case pick < 20:
		return history.OpCreate
	case pick < 55:
		return history.OpUpdate
	case pick < 75:
		return history.OpDelete
	default:
		return history.OpGet
	}
}

func runCreate(ctx context.Context, cli *clientv3.Client, key, value string) (bool, int64, int64, error) {
	txnResp, err := cli.Txn(ctx).
		If(clientv3.Compare(clientv3.ModRevision(key), "=", 0)).
		Then(clientv3.OpPut(key, value)).
		Else(clientv3.OpGet(key)).
		Commit()
	if err != nil {
		return false, 0, 0, err
	}
	respRev := int64(0)
	if txnResp.Header != nil {
		respRev = txnResp.Header.Revision
	}
	return txnResp.Succeeded, respRev, extractFailureModRevision(txnResp), nil
}

func runUpdate(ctx context.Context, cli *clientv3.Client, key, value string, expectedModRevision int64) (bool, int64, int64, error) {
	txnResp, err := cli.Txn(ctx).
		If(clientv3.Compare(clientv3.ModRevision(key), "=", expectedModRevision)).
		Then(clientv3.OpPut(key, value)).
		Else(clientv3.OpGet(key)).
		Commit()
	if err != nil {
		return false, 0, 0, err
	}
	respRev := int64(0)
	if txnResp.Header != nil {
		respRev = txnResp.Header.Revision
	}
	return txnResp.Succeeded, respRev, extractFailureModRevision(txnResp), nil
}

func runDelete(ctx context.Context, cli *clientv3.Client, key string, expectedModRevision int64) (bool, int64, int64, error) {
	txnResp, err := cli.Txn(ctx).
		If(clientv3.Compare(clientv3.ModRevision(key), "=", expectedModRevision)).
		Then(clientv3.OpDelete(key)).
		Else(clientv3.OpGet(key)).
		Commit()
	if err != nil {
		return false, 0, 0, err
	}
	respRev := int64(0)
	if txnResp.Header != nil {
		respRev = txnResp.Header.Revision
	}
	return txnResp.Succeeded, respRev, extractFailureModRevision(txnResp), nil
}

func readCurrent(ctx context.Context, cli *clientv3.Client, key string) (found bool, value string, modRevision int64, headerRevision int64, err error) {
	resp, err := cli.Get(ctx, key)
	if err != nil {
		return false, "", 0, 0, err
	}
	if resp.Header != nil {
		headerRevision = resp.Header.Revision
	}
	if len(resp.Kvs) == 0 {
		return false, "", 0, headerRevision, nil
	}
	kv := resp.Kvs[0]
	return true, string(kv.Value), kv.ModRevision, headerRevision, nil
}

func extractFailureModRevision(resp *clientv3.TxnResponse) int64 {
	if resp == nil || resp.Succeeded || len(resp.Responses) == 0 {
		return 0
	}
	rng := resp.Responses[0].GetResponseRange()
	if rng == nil || len(rng.Kvs) == 0 {
		return 0
	}
	return rng.Kvs[0].ModRevision
}

func updateMaxRevision(ptr *int64, value int64) {
	for {
		old := atomic.LoadInt64(ptr)
		if value <= old {
			return
		}
		if atomic.CompareAndSwapInt64(ptr, old, value) {
			return
		}
	}
}

func writeJSONL(path string, in <-chan history.Record) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()

	buffer := bufio.NewWriterSize(file, 1<<20)
	defer buffer.Flush()

	enc := json.NewEncoder(buffer)
	for r := range in {
		if err := enc.Encode(r); err != nil {
			return err
		}
	}
	return nil
}

func splitNonEmpty(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func exitf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

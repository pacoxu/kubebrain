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

package etcd

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"go.etcd.io/etcd/api/v3/etcdserverpb"

	proto "github.com/kubewharf/kubebrain-client/api/v2rpc"
	backendpkg "github.com/kubewharf/kubebrain/pkg/backend"
)

type fakeDeleteBackend struct {
	backendpkg.Backend
	resp *proto.DeleteResponse
	err  error
}

var benchmarkDeleteResp *etcdserverpb.TxnResponse

func (f *fakeDeleteBackend) Delete(_ context.Context, _ *proto.DeleteRequest) (*proto.DeleteResponse, error) {
	return f.resp, f.err
}

func TestBackendShimDeleteSuccessReturnsDeleteRange(t *testing.T) {
	backend := &fakeDeleteBackend{
		resp: &proto.DeleteResponse{
			Header: &proto.ResponseHeader{
				Revision: 123,
			},
			Succeeded: true,
			Kv: &proto.KeyValue{
				Key:      []byte("/registry/pods/default/p0"),
				Value:    []byte("payload"),
				Revision: 101,
			},
		},
	}
	shim := NewBackendShim(backend, nil)

	resp, err := shim.Delete(context.Background(), []byte("/registry/pods/default/p0"), 101)
	require.NoError(t, err)
	require.True(t, resp.Succeeded)
	require.Equal(t, int64(123), resp.Header.Revision)
	require.Len(t, resp.Responses, 1)

	deleteResp := resp.Responses[0].GetResponseDeleteRange()
	require.NotNil(t, deleteResp)
	require.Equal(t, int64(123), deleteResp.Header.Revision)
	require.Equal(t, int64(1), deleteResp.Deleted)
	require.Len(t, deleteResp.PrevKvs, 1)
	require.Equal(t, []byte("/registry/pods/default/p0"), deleteResp.PrevKvs[0].Key)
	require.Equal(t, []byte("payload"), deleteResp.PrevKvs[0].Value)
	require.Equal(t, int64(101), deleteResp.PrevKvs[0].ModRevision)
	require.Nil(t, resp.Responses[0].GetResponseRange())
}

func TestBackendShimDeleteConflictReturnsRange(t *testing.T) {
	backend := &fakeDeleteBackend{
		resp: &proto.DeleteResponse{
			Header: &proto.ResponseHeader{
				Revision: 456,
			},
			Succeeded: false,
			Kv: &proto.KeyValue{
				Key:      []byte("/registry/pods/default/p0"),
				Value:    []byte("latest"),
				Revision: 202,
			},
		},
	}
	shim := NewBackendShim(backend, nil)

	resp, err := shim.Delete(context.Background(), []byte("/registry/pods/default/p0"), 101)
	require.NoError(t, err)
	require.False(t, resp.Succeeded)
	require.Equal(t, int64(456), resp.Header.Revision)
	require.Len(t, resp.Responses, 1)

	rangeResp := resp.Responses[0].GetResponseRange()
	require.NotNil(t, rangeResp)
	require.Equal(t, int64(456), rangeResp.Header.Revision)
	require.Equal(t, int64(1), rangeResp.Count)
	require.Len(t, rangeResp.Kvs, 1)
	require.Equal(t, []byte("/registry/pods/default/p0"), rangeResp.Kvs[0].Key)
	require.Equal(t, []byte("latest"), rangeResp.Kvs[0].Value)
	require.Equal(t, int64(202), rangeResp.Kvs[0].ModRevision)
	require.Nil(t, resp.Responses[0].GetResponseDeleteRange())
}

func TestBackendShimDeleteConflictWithoutKvReturnsEmptyRange(t *testing.T) {
	backend := &fakeDeleteBackend{
		resp: &proto.DeleteResponse{
			Header: &proto.ResponseHeader{
				Revision: 789,
			},
			Succeeded: false,
			Kv:        nil,
		},
	}
	shim := NewBackendShim(backend, nil)

	resp, err := shim.Delete(context.Background(), []byte("/registry/pods/default/p0"), 101)
	require.NoError(t, err)
	require.False(t, resp.Succeeded)
	require.Len(t, resp.Responses, 1)

	rangeResp := resp.Responses[0].GetResponseRange()
	require.NotNil(t, rangeResp)
	require.Equal(t, int64(0), rangeResp.Count)
	require.Len(t, rangeResp.Kvs, 0)
}

func BenchmarkBackendShimDelete(b *testing.B) {
	ctx := context.Background()
	key := []byte("/registry/pods/default/p0")

	b.Run("success-delete-range", func(b *testing.B) {
		backend := &fakeDeleteBackend{
			resp: &proto.DeleteResponse{
				Header: &proto.ResponseHeader{
					Revision: 123,
				},
				Succeeded: true,
				Kv: &proto.KeyValue{
					Key:      key,
					Value:    []byte("payload"),
					Revision: 101,
				},
			},
		}
		shim := NewBackendShim(backend, nil)
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			resp, err := shim.Delete(ctx, key, 101)
			if err != nil {
				b.Fatalf("delete failed: %v", err)
			}
			benchmarkDeleteResp = resp
		}
	})

	b.Run("conflict-range", func(b *testing.B) {
		backend := &fakeDeleteBackend{
			resp: &proto.DeleteResponse{
				Header: &proto.ResponseHeader{
					Revision: 456,
				},
				Succeeded: false,
				Kv: &proto.KeyValue{
					Key:      key,
					Value:    []byte("latest"),
					Revision: 202,
				},
			},
		}
		shim := NewBackendShim(backend, nil)
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			resp, err := shim.Delete(ctx, key, 101)
			if err != nil {
				b.Fatalf("delete failed: %v", err)
			}
			benchmarkDeleteResp = resp
		}
	})
}

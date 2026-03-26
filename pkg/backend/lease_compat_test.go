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

package backend

import (
	"context"
	"path"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	proto "github.com/kubewharf/kubebrain-client/api/v2rpc"
)

func TestCreateRequestLeaseIsApplied(t *testing.T) {
	suite, closer := newTestSuites(t, memKvStorage)
	defer closer()

	const ttlSeconds = int64(1)
	key := path.Join(prefix, "lease-compat", "create")
	_, err := suite.backend.Create(context.Background(), &proto.CreateRequest{
		Key:   []byte(key),
		Value: []byte("value"),
		Lease: ttlSeconds,
	})
	require.NoError(t, err)

	require.Eventually(t, func() bool {
		resp, getErr := suite.backend.Get(context.Background(), &proto.GetRequest{
			Key: []byte(key),
		})
		return getErr == nil && resp.Kv == nil
	}, 3*time.Second, 100*time.Millisecond)
}

func TestUpdateCreatePathLeaseIsApplied(t *testing.T) {
	suite, closer := newTestSuites(t, memKvStorage)
	defer closer()

	const ttlSeconds = int64(1)
	key := path.Join(prefix, "lease-compat", "update-create")
	_, err := suite.backend.Update(context.Background(), &proto.UpdateRequest{
		Kv: &proto.KeyValue{
			Key:      []byte(key),
			Value:    []byte("value"),
			Revision: 0,
		},
		Lease: ttlSeconds,
	})
	require.NoError(t, err)

	require.Eventually(t, func() bool {
		resp, getErr := suite.backend.Get(context.Background(), &proto.GetRequest{
			Key: []byte(key),
		})
		return getErr == nil && resp.Kv == nil
	}, 3*time.Second, 100*time.Millisecond)
}

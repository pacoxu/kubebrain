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

package history

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
)

// Operation is the operation type in history records.
type Operation string

const (
	OpCreate  Operation = "create"
	OpUpdate  Operation = "update"
	OpDelete  Operation = "delete"
	OpGet     Operation = "get"
	OpCompact Operation = "compact"
)

// Record is one completed operation in Jepsen-style history.
type Record struct {
	ID                  int64     `json:"id"`
	ClientID            int       `json:"client_id"`
	Operation           Operation `json:"operation"`
	Key                 string    `json:"key,omitempty"`
	RequestValue        string    `json:"request_value,omitempty"`
	ExpectedModRevision int64     `json:"expected_mod_revision,omitempty"`
	CompactRevision     int64     `json:"compact_revision,omitempty"`
	InvokeUnixNano      int64     `json:"invoke_unix_nano"`
	FinishUnixNano      int64     `json:"finish_unix_nano"`
	Succeeded           bool      `json:"succeeded"`
	ResponseRevision    int64     `json:"response_revision,omitempty"`
	ResponseModRevision int64     `json:"response_mod_revision,omitempty"`
	KeyFound            bool      `json:"key_found"`
	ResponseValue       string    `json:"response_value,omitempty"`
	TransportError      string    `json:"transport_error,omitempty"`
	Note                string    `json:"note,omitempty"`
}

// LoadJSONL loads history records from a JSONL file.
func LoadJSONL(path string) ([]Record, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	// Allow up to 10MB per line for large event payloads.
	scanner.Buffer(make([]byte, 1024), 10*1024*1024)

	records := make([]Record, 0, 1024)
	for scanner.Scan() {
		var r Record
		if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
			return nil, err
		}
		records = append(records, r)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return records, nil
}

// SortByFinish sorts records by finish time, then invocation time, then ID.
func SortByFinish(records []Record) {
	sort.Slice(records, func(i, j int) bool {
		if records[i].FinishUnixNano != records[j].FinishUnixNano {
			return records[i].FinishUnixNano < records[j].FinishUnixNano
		}
		if records[i].InvokeUnixNano != records[j].InvokeUnixNano {
			return records[i].InvokeUnixNano < records[j].InvokeUnixNano
		}
		return records[i].ID < records[j].ID
	})
}

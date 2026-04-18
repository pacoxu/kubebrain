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
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/kubewharf/kubebrain/test/jepsen/history"
)

type violation struct {
	Invariant string `json:"invariant"`
	RecordID  int64  `json:"record_id"`
	Key       string `json:"key,omitempty"`
	Detail    string `json:"detail"`
}

type invariantResult struct {
	Name       string      `json:"name"`
	Passed     bool        `json:"passed"`
	Violations []violation `json:"violations,omitempty"`
}

type report struct {
	GeneratedAtUTC        string                 `json:"generated_at_utc"`
	HistoryPath           string                 `json:"history_path"`
	TotalRecords          int                    `json:"total_records"`
	SuccessfulRecords     int                    `json:"successful_records"`
	TransportErrorRecords int                    `json:"transport_error_records"`
	ByOperation           map[string]int         `json:"by_operation"`
	MaxResponseRevision   int64                  `json:"max_response_revision"`
	Invariants            []invariantResult      `json:"invariants"`
	Passed                bool                   `json:"passed"`
	Summary               map[string]interface{} `json:"summary"`
}

func main() {
	var (
		historyPath = flag.String("history", "test/jepsen/artifacts/history.jsonl", "history JSONL path")
		reportPath  = flag.String("report", "test/jepsen/artifacts/report.json", "checker report path")
	)
	flag.Parse()

	records, err := history.LoadJSONL(*historyPath)
	if err != nil {
		exitf("load history failed: %v", err)
	}
	if len(records) == 0 {
		exitf("history is empty: %s", *historyPath)
	}

	history.SortByFinish(records)

	rep := buildBaseReport(*historyPath, records)
	invariants := make([]invariantResult, 0, 3)

	invariants = append(invariants, evaluate("global_response_revision_monotonic", checkGlobalRevisionMonotonic(records)))
	invariants = append(invariants, evaluate("per_key_write_revision_strictly_increasing", checkPerKeyWriteRevision(records)))
	invariants = append(invariants, evaluate("no_phantom_resurrection_after_delete", checkNoPhantomResurrection(records)))

	rep.Invariants = invariants
	rep.Passed = true
	for _, inv := range invariants {
		if !inv.Passed {
			rep.Passed = false
			break
		}
	}

	rep.Summary = map[string]interface{}{
		"note": "This checker validates Jepsen-style invariants from operation history; full linearizability checking is out of scope for this first-stage harness.",
	}

	if err := os.MkdirAll(filepath.Dir(*reportPath), 0755); err != nil {
		exitf("create report directory failed: %v", err)
	}
	if err := writeReport(*reportPath, rep); err != nil {
		exitf("write report failed: %v", err)
	}

	fmt.Printf("checker report written to %s (passed=%v)\n", *reportPath, rep.Passed)
	if !rep.Passed {
		os.Exit(1)
	}
}

func buildBaseReport(historyPath string, records []history.Record) report {
	byOp := make(map[string]int)
	success := 0
	transportErr := 0
	maxRevision := int64(0)

	for _, r := range records {
		byOp[string(r.Operation)]++
		if r.Succeeded {
			success++
		}
		if r.TransportError != "" {
			transportErr++
		}
		if r.ResponseRevision > maxRevision {
			maxRevision = r.ResponseRevision
		}
	}

	return report{
		GeneratedAtUTC:        time.Now().UTC().Format(time.RFC3339),
		HistoryPath:           historyPath,
		TotalRecords:          len(records),
		SuccessfulRecords:     success,
		TransportErrorRecords: transportErr,
		ByOperation:           byOp,
		MaxResponseRevision:   maxRevision,
	}
}

func evaluate(name string, violations []violation) invariantResult {
	return invariantResult{
		Name:       name,
		Passed:     len(violations) == 0,
		Violations: violations,
	}
}

func checkGlobalRevisionMonotonic(records []history.Record) []violation {
	prev := int64(-1)
	violations := make([]violation, 0)
	for _, r := range records {
		if !r.Succeeded || r.ResponseRevision <= 0 {
			continue
		}
		if prev > r.ResponseRevision {
			violations = append(violations, violation{
				Invariant: "global_response_revision_monotonic",
				RecordID:  r.ID,
				Key:       r.Key,
				Detail:    fmt.Sprintf("response revision decreased from %d to %d", prev, r.ResponseRevision),
			})
		}
		if r.ResponseRevision > prev {
			prev = r.ResponseRevision
		}
	}
	return violations
}

func checkPerKeyWriteRevision(records []history.Record) []violation {
	lastWriteRevision := make(map[string]int64)
	violations := make([]violation, 0)

	for _, r := range records {
		if !r.Succeeded {
			continue
		}
		if r.Operation != history.OpCreate && r.Operation != history.OpUpdate && r.Operation != history.OpDelete {
			continue
		}
		if r.Key == "" || r.ResponseRevision <= 0 {
			continue
		}
		prev := lastWriteRevision[r.Key]
		if prev >= r.ResponseRevision {
			violations = append(violations, violation{
				Invariant: "per_key_write_revision_strictly_increasing",
				RecordID:  r.ID,
				Key:       r.Key,
				Detail:    fmt.Sprintf("write revision is not strictly increasing: previous=%d current=%d", prev, r.ResponseRevision),
			})
		}
		if r.ResponseRevision > prev {
			lastWriteRevision[r.Key] = r.ResponseRevision
		}
	}
	return violations
}

type deletionState struct {
	revision   int64
	finishNano int64
}

func checkNoPhantomResurrection(records []history.Record) []violation {
	lastDelete := make(map[string]deletionState)
	violations := make([]violation, 0)

	for _, r := range records {
		if !r.Succeeded {
			continue
		}

		switch r.Operation {
		case history.OpDelete:
			if r.Key != "" && r.ResponseRevision > 0 {
				lastDelete[r.Key] = deletionState{
					revision:   r.ResponseRevision,
					finishNano: r.FinishUnixNano,
				}
			}
		case history.OpCreate, history.OpUpdate:
			if r.Key != "" {
				delete(lastDelete, r.Key)
			}
		case history.OpGet:
			if !r.KeyFound || r.Key == "" || r.ResponseModRevision <= 0 {
				continue
			}
			del, ok := lastDelete[r.Key]
			if !ok {
				continue
			}
			// Ignore overlapping operations where GET invocation started before delete finished.
			if r.InvokeUnixNano <= del.finishNano {
				continue
			}
			if r.ResponseModRevision <= del.revision {
				violations = append(violations, violation{
					Invariant: "no_phantom_resurrection_after_delete",
					RecordID:  r.ID,
					Key:       r.Key,
					Detail:    fmt.Sprintf("get observed mod_revision=%d after delete revision=%d", r.ResponseModRevision, del.revision),
				})
			}
		}
	}
	return violations
}

func writeReport(path string, r report) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()

	enc := json.NewEncoder(file)
	enc.SetIndent("", "  ")
	return enc.Encode(r)
}

func exitf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

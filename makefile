
.PHONY: badger
badger:
	bash ./build/build-badger.sh


.PHONY: tikv
tikv:
	bash ./build/build-tikv.sh

.PHONY: test-coverage
test-coverage:
	go test -coverprofile=coverage.out -cover=true -coverpkg=./pkg/... ./...

.PHONY: e2e-kind
e2e-kind:
	bash ./test/e2e/kind/run.sh

.PHONY: bench-kind-compare
bench-kind-compare:
	bash ./test/benchmark/kind/compare.sh

.PHONY: bench-kwok-compare
bench-kwok-compare:
	bash ./test/benchmark/kwok/compare.sh

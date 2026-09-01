.PHONY: build test clean lint

build:
	go build -o bin/mrtop ./cmd/mrtop

test:
	go test ./...
	bash tests/watcher_state.sh

clean:
	rm -f bin/mrtop

lint:
	shellcheck watch.sh fix-mr.sh lib.sh bin/mrwatch install.sh uninstall.sh get.sh docs/demo-state.sh
	gofmt -l cmd/
	go vet ./...

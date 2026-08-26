.PHONY: build clean lint

build:
	go build -o bin/mrtop ./cmd/mrtop

clean:
	rm -f bin/mrtop

lint:
	shellcheck -S warning watch.sh fix-mr.sh lib.sh bin/mrwatch install.sh uninstall.sh
	go vet ./...

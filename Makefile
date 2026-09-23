.PHONY: all lint test install

all: lint test

lint:
	shellcheck cc-monitor.sh tests/run.sh

test:
	bash tests/run.sh

install:
	./cc-monitor.sh --install

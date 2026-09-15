.PHONY: build app run install daemon clean logs test

build:
	swift build

app:
	./Scripts/build-app.sh release

run: app
	open build/Relay.app

install: app
	./Scripts/install.sh

test:
	swift test

daemon:
	swift build --product relay-daemon
	$$(swift build --show-bin-path)/relay-daemon

clean:
	rm -rf .build build

logs:
	tail -f "$$HOME/Library/Application Support/Relay/Logs/daemon.log"

.PHONY: build app run install dev dev-install daemon clean logs test

build:
	swift build

app:
	./Scripts/build-app.sh release

run: app
	open build/Relay.app

install: app
	./Scripts/install.sh

# The build that stands beside the released app instead of replacing it: its
# own identity, its own daemon, its own workspace. Work in Relay, build in
# Relay Dev, and neither can end the other's sessions.
dev:
	RELAY_FLAVOUR=dev ./Scripts/build-app.sh release

dev-install: dev
	RELAY_FLAVOUR=dev ./Scripts/install.sh

test:
	swift test

daemon:
	swift build --product relay-daemon
	$$(swift build --show-bin-path)/relay-daemon

clean:
	rm -rf .build build

logs:
	tail -f "$$HOME/.relay/Logs/daemon.log"

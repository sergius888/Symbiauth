.PHONY: setup build run ios mac agent webext lint test clean

setup:
	cd packages/webext && npm i
	rustup toolchain install stable

build: mac agent webext

mac:
	xcodebuild -project apps/tls-terminator-macos/ArmadilloTLS.xcodeproj -scheme ArmadilloTLS -configuration Debug -derivedDataPath apps/tls-terminator-macos/DerivedData

agent:
	cd apps/agent-macos && cargo build

webext:
	cd packages/webext && npm run build

run:
	# Start Rust agent (Swift TLS terminator should be started separately)
	apps/agent-macos/target/debug/agent-macos

run-swift:
	# Start Swift TLS terminator
	apps/tls-terminator-macos/DerivedData/Build/Products/Debug/ArmadilloTLS.app/Contents/MacOS/ArmadilloTLS

lint:
	swiftlint || true
	cd apps/agent-macos && cargo fmt --all && cargo clippy -D warnings
	cd packages/webext && npm run lint

test:
	cd apps/agent-macos && cargo test
	cd packages/webext && npm test

clean:
	cd apps/agent-macos && cargo clean
	cd packages/webext && npm run clean || true
	rm -rf apps/tls-terminator-macos/DerivedData
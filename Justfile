set shell := ["bash", "-cu"]

default:
    @just --list

# --- TS / Node ---

install:
    pnpm install

build:
    pnpm -r build

lint:
    pnpm -r lint

typecheck:
    pnpm -r typecheck

test:
    pnpm test

test-worker-container:
    pnpm test:worker-container

format:
    pnpm format

# --- Apps ---

worker-dev:
    pnpm --filter @scorebug/control-plane dev:worker

home-daemon-dev:
    pnpm --filter @scorebug/home-daemon dev

# --- iOS ---

ios-generate:
    cd ios && xcodegen generate --spec Project.yml

ios-build: ios-generate
    xcodebuild build -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData/Local ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO

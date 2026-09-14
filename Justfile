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

doctor:
    pnpm run doctor

test-container:
    pnpm test:container

test-local:
    pnpm test:local

test-apple:
    pnpm test:apple

format:
    pnpm format

# --- App-level (filled in as scaffolds land) ---

control-plane-dev:
    pnpm --filter @scorebug/control-plane dev

home-daemon-dev:
    pnpm --filter @scorebug/home-daemon dev

overlay-dev:
    pnpm --filter @scorebug/overlay dev

scoring-dev:
    pnpm --filter @scorebug/scoring dev

# --- iOS ---

ios-build:
    cd ios && xcodebuild -scheme Scorebug -destination 'generic/platform=iOS' build

ios-lint:
    cd ios && swiftlint

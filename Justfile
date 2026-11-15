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

test-container:
    pnpm test:container

test-local:
    pnpm test:local

test-scoring:
    pnpm test:scoring

test-relay:
    pnpm test:relay

format:
    pnpm format

# --- Apps ---

api-dev:
    pnpm dev:api

control-plane-dev:
    pnpm --filter @scorebug/control-plane dev

home-daemon-dev:
    pnpm --filter @scorebug/home-daemon dev

# --- iOS ---

ios-generate:
    cd ios && xcodegen generate --spec Project.yml && xcodegen generate --spec Scoring.yml

ios-build: ios-generate
    xcodebuild build -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData/Local CODE_SIGNING_ALLOWED=NO

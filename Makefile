BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/Castor.app

.PHONY: project build test run clean

project: project.yml
	xcodegen generate

build: project
	xcodebuild -project Castor.xcodeproj -scheme Castor -configuration Debug \
		-derivedDataPath $(BUILD_DIR) build

test:
	swift test --package-path Packages/CastorEngine

run: build
	open $(APP)

clean:
	rm -rf $(BUILD_DIR) Castor.xcodeproj

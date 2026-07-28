XCODE_SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC ?= $(shell xcrun --find swiftc)
TARGET_X86 = x86_64-apple-macosx13.0
TARGET_ARM = arm64-apple-macosx13.0
SWIFT_BUILD_FLAGS ?= -O -whole-module-optimization
CODESIGN_IDENTITY ?= -
NOTARYTOOL_PROFILE ?=
BUILD_DIR = .build
OUTPUT = $(BUILD_DIR)/OpenFire

SWIFT_FILES := $(shell find Sources/App -name "*.swift" | sort)
FRAMEWORKS = -framework Cocoa -framework Carbon -framework JavaScriptCore

APP_NAME = OpenFire
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS = $(APP_DIR)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources
DMG_NAME = $(APP_NAME).dmg
DMG_WINDOW_WIDTH = 640
DMG_WINDOW_HEIGHT = 360
DMG_ICON_SIZE = 96
DMG_BACKGROUND = $(BUILD_DIR)/dmg-background.png

.DEFAULT_GOAL := help

.PHONY: help all clean force package release run test

help:
	@echo "OpenFire 可用 make 命令："
	@echo ""
	@echo "  make / make help  显示本说明，不执行构建。"
	@echo "  make all          编译 universal OpenFire 二进制到 $(OUTPUT)。"
	@echo "  make package      创建仅供本地验证的 $(APP_NAME).app 和 $(DMG_NAME)。"
	@echo "  make release      Developer ID 签名、公证并验证正式发布镜像。"
	@echo "  make run          打包、重置开发构建的 Accessibility 权限，然后启动 OpenFire。"
	@echo "  make test         运行 Swift 测试。"
	@echo "  make clean        删除 $(BUILD_DIR)。"
	@echo ""
	@echo "需要执行具体任务时，请显式运行对应命令，例如：make package"

all: $(OUTPUT)
	@echo "✅ Build succeeded: $(OUTPUT)"
	@rm -rf $(BUILD_DIR)/Plugins
	@cp -R Plugins $(BUILD_DIR)/Plugins

$(OUTPUT): force $(SWIFT_FILES) Makefile
	@mkdir -p $(BUILD_DIR)
	@echo "🔨 Compiling for x86_64..."
		$(SWIFTC) $(SWIFT_BUILD_FLAGS) -o $(OUTPUT)_x86 $(SWIFT_FILES) $(FRAMEWORKS) -target $(TARGET_X86) -sdk $(XCODE_SDK)
	@echo "🔨 Compiling for arm64..."
		$(SWIFTC) $(SWIFT_BUILD_FLAGS) -o $(OUTPUT)_arm $(SWIFT_FILES) $(FRAMEWORKS) -target $(TARGET_ARM) -sdk $(XCODE_SDK)
	@echo "🔗 Creating Universal Binary..."
	lipo -create -output $(OUTPUT) $(OUTPUT)_x86 $(OUTPUT)_arm
	@rm $(OUTPUT)_x86 $(OUTPUT)_arm

force:

run: package
	@echo "🛑 Stopping existing OpenFire instances..."
	@killall OpenFire 2>/dev/null || true
	@echo "🧹 Clearing stale TCC Accessibility permissions for new build..."
	@tccutil reset Accessibility com.openfire.app 2>/dev/null || true
	@echo "🔥 Starting OpenFire..."
	@open $(APP_DIR)

package: all
	@echo "📦 Packaging $(APP_NAME).app..."
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_MACOS)
	@mkdir -p $(APP_RESOURCES)/Plugins
	@cp $(OUTPUT) $(APP_MACOS)/
	@cp Sources/App/Resources/Info.plist $(APP_CONTENTS)/
	@cp -R Sources/App/Resources/*.lproj $(APP_RESOURCES)/
	@cp -r Plugins/* $(APP_RESOURCES)/Plugins/
	@cp Sources/App/Resources/AppIcon.icns $(APP_RESOURCES)/
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "⚠️  Ad-hoc signing $(APP_NAME).app. Set CODESIGN_IDENTITY to create a distributable Developer ID build."; \
		codesign --force --deep --sign - $(APP_DIR); \
	else \
		echo "✍️ Signing $(APP_NAME).app with $(CODESIGN_IDENTITY)..."; \
		codesign --force --deep --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" $(APP_DIR); \
	fi
	@codesign --verify --deep --strict --verbose=2 $(APP_DIR)
	@echo "💿 Creating $(DMG_NAME)..."
	@command -v create-dmg >/dev/null || { echo "❌ create-dmg is required. Install it with: brew install create-dmg"; exit 1; }
	@rm -rf $(BUILD_DIR)/dmg_stage
	@mkdir -p $(BUILD_DIR)/dmg_stage
	@swift Tools/create_dmg_background.swift $(DMG_BACKGROUND) $(DMG_WINDOW_WIDTH) $(DMG_WINDOW_HEIGHT)
	@cp -a $(APP_DIR) $(BUILD_DIR)/dmg_stage/
	@STAGE_PATH="$$(cd $(BUILD_DIR)/dmg_stage && pwd)"; \
	if osascript -e "tell application \"Finder\" to make alias file to POSIX file \"/Applications\" at POSIX file \"$${STAGE_PATH}\"" >/dev/null 2>&1; then \
		ALIAS_PATH="$$(find $(BUILD_DIR)/dmg_stage -maxdepth 1 -type f ! -name '.DS_Store' ! -name '*.app' -print -quit)"; \
		if [ -n "$${ALIAS_PATH}" ] && [ "$${ALIAS_PATH}" != "$(BUILD_DIR)/dmg_stage/Applications" ]; then mv "$${ALIAS_PATH}" $(BUILD_DIR)/dmg_stage/Applications; fi; \
	else \
		ln -s /Applications $(BUILD_DIR)/dmg_stage/Applications; \
	fi
	@APP_FOLDER_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"; \
	ICON_COPY="$(BUILD_DIR)/dmg_stage/.ApplicationsFolderIcon.icns"; \
	ICON_RSRC="$(BUILD_DIR)/dmg_stage/.ApplicationsIcon.rsrc"; \
	if [ -f "$${APP_FOLDER_ICON}" ] && [ -f "$(BUILD_DIR)/dmg_stage/Applications" ]; then \
		cp "$${APP_FOLDER_ICON}" "$${ICON_COPY}"; \
		sips -i "$${ICON_COPY}" >/dev/null 2>&1 || true; \
		if DeRez -only icns "$${ICON_COPY}" > "$${ICON_RSRC}" 2>/dev/null; then \
			Rez -append "$${ICON_RSRC}" -o "$(BUILD_DIR)/dmg_stage/Applications" 2>/dev/null && \
			SetFile -a C "$(BUILD_DIR)/dmg_stage/Applications" || true; \
		fi; \
		rm -f "$${ICON_COPY}" "$${ICON_RSRC}"; \
	fi
	@rm -f $(BUILD_DIR)/$(DMG_NAME)
	@create-dmg \
		--volname "$(APP_NAME)" \
		--window-size $(DMG_WINDOW_WIDTH) $(DMG_WINDOW_HEIGHT) \
		--background "$(DMG_BACKGROUND)" \
		--icon-size $(DMG_ICON_SIZE) \
		--icon "$(APP_NAME).app" 180 170 \
		--icon "Applications" 460 170 \
		--hide-extension "$(APP_NAME).app" \
		--no-internet-enable \
		--format UDZO \
		$(BUILD_DIR)/$(DMG_NAME) \
		$(BUILD_DIR)/dmg_stage >/dev/null
	@if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		echo "✍️ Signing $(DMG_NAME) with $(CODESIGN_IDENTITY)..."; \
		codesign --force --timestamp --sign "$(CODESIGN_IDENTITY)" $(BUILD_DIR)/$(DMG_NAME); \
		codesign --verify --strict --verbose=2 $(BUILD_DIR)/$(DMG_NAME); \
	fi
	@hdiutil verify $(BUILD_DIR)/$(DMG_NAME)
	@rm -rf $(BUILD_DIR)/dmg_stage
	@echo "✅ Local verification package created at $(BUILD_DIR)/$(DMG_NAME)"
	@echo "ℹ️  This target does not notarize. Use 'make release' for a distributable build."

release:
	@if [ "$(CODESIGN_IDENTITY)" = "-" ] || [ -z "$(CODESIGN_IDENTITY)" ]; then \
		echo "❌ release requires a Developer ID Application CODESIGN_IDENTITY."; \
		exit 1; \
	fi
	@if [ -z "$(NOTARYTOOL_PROFILE)" ]; then \
		echo "❌ release requires a configured NOTARYTOOL_PROFILE."; \
		exit 1; \
	fi
	@$(MAKE) package CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)"
	@echo "📨 Submitting $(DMG_NAME) for notarization..."
	@xcrun notarytool submit $(BUILD_DIR)/$(DMG_NAME) --keychain-profile "$(NOTARYTOOL_PROFILE)" --wait
	@xcrun stapler staple $(BUILD_DIR)/$(DMG_NAME)
	@xcrun stapler validate $(BUILD_DIR)/$(DMG_NAME)
	@codesign --verify --deep --strict --verbose=2 $(APP_DIR)
	@codesign --verify --strict --verbose=2 $(BUILD_DIR)/$(DMG_NAME)
	@hdiutil verify $(BUILD_DIR)/$(DMG_NAME)
	@echo "✅ Signed, notarized, and validated release at $(BUILD_DIR)/$(DMG_NAME)"

clean:
	rm -rf $(BUILD_DIR)

test:
	@echo "🧪 Running Tests..."
	swift test

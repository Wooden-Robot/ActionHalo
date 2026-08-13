XCODE_SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC ?= $(shell xcrun --find swiftc)
TARGET_X86 = x86_64-apple-macosx13.0
TARGET_ARM = arm64-apple-macosx13.0
SWIFT_BUILD_FLAGS ?= -O -whole-module-optimization
VERSION ?=
ARTIFACT_PLIST ?=
APP_ENTITLEMENTS = OpenFire.entitlements
SPARKLE_VERSION = 2.9.4
SPARKLE_ACCOUNT ?= OpenFire
BUILD_DIR = .build
OUTPUT = $(BUILD_DIR)/OpenFire
SPARKLE_DISTRIBUTION = $(BUILD_DIR)/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK_PARENT = $(SPARKLE_DISTRIBUTION)/Sparkle.xcframework/macos-arm64_x86_64
SPARKLE_FRAMEWORK = $(SPARKLE_FRAMEWORK_PARENT)/Sparkle.framework
SPARKLE_TOOLS = $(SPARKLE_DISTRIBUTION)/bin
SPARKLE_LICENSE = $(SPARKLE_DISTRIBUTION)/LICENSE
APPCAST_DIR = $(BUILD_DIR)/appcast-input
APPCAST_PATH = $(BUILD_DIR)/appcast.xml

SWIFT_FILES := $(shell find Sources/App -name "*.swift" | sort)
FRAMEWORKS = -framework Cocoa -framework Carbon -framework JavaScriptCore

APP_NAME = OpenFire
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS = $(APP_DIR)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources
APP_FRAMEWORKS = $(APP_CONTENTS)/Frameworks
DMG_NAME = $(APP_NAME).dmg
DMG_WINDOW_WIDTH = 640
DMG_WINDOW_HEIGHT = 360
DMG_ICON_SIZE = 96
DMG_BACKGROUND = $(BUILD_DIR)/dmg-background.png

.DEFAULT_GOAL := help

.PHONY: help all clean force dependencies package release generate-appcast publish-release-assets verify-release-repository verify-release-version verify-release-entitlements verify-sparkle-update run test

help:
	@echo "OpenFire 可用 make 命令："
	@echo ""
	@echo "  make / make help  显示本说明，不执行构建。"
	@echo "  make all          编译 universal OpenFire 二进制到 $(OUTPUT)。"
	@echo "  make package      创建 ad-hoc 签名的社区版 $(APP_NAME).app 和 $(DMG_NAME)。"
	@echo "  make release      校验版本/tag 后打包社区版并生成 Sparkle 签名更新源。"
	@echo "  make publish-release-assets  将 DMG 与签名 appcast 上传到草稿 GitHub Release。"
	@echo "                    校验远端摘要后才公开；正式目标均需显式 VERSION 和精确 tag。"
	@echo "  make run          打包、重置开发构建的 Accessibility 权限，然后启动 OpenFire。"
	@echo "  make test         运行 Swift 测试。"
	@echo "  make clean        删除 $(BUILD_DIR)。"
	@echo ""
	@echo "需要执行具体任务时，请显式运行对应命令，例如：make package"

dependencies:
	@if [ ! -d "$(SPARKLE_FRAMEWORK)" ] || \
	   [ "$$(plutil -extract pins.0.state.version raw Package.resolved 2>/dev/null)" != "$(SPARKLE_VERSION)" ]; then \
		echo "📦 Resolving Sparkle $(SPARKLE_VERSION)..."; \
		swift package resolve; \
	fi
	@test -d "$(SPARKLE_FRAMEWORK)" || { echo "❌ Sparkle.framework is missing after dependency resolution."; exit 1; }
	@test -f "$(SPARKLE_LICENSE)" || { echo "❌ Sparkle license is missing after dependency resolution."; exit 1; }

all: dependencies $(OUTPUT)
	@echo "✅ Build succeeded: $(OUTPUT)"
	@rm -rf $(BUILD_DIR)/Plugins
	@cp -R Plugins $(BUILD_DIR)/Plugins

$(OUTPUT): force $(SWIFT_FILES) Makefile Package.swift Package.resolved
	@mkdir -p $(BUILD_DIR)
	@echo "🔨 Compiling for x86_64..."
		$(SWIFTC) $(SWIFT_BUILD_FLAGS) -o $(OUTPUT)_x86 $(SWIFT_FILES) $(FRAMEWORKS) -F "$(SPARKLE_FRAMEWORK_PARENT)" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -target $(TARGET_X86) -sdk $(XCODE_SDK)
	@echo "🔨 Compiling for arm64..."
		$(SWIFTC) $(SWIFT_BUILD_FLAGS) -o $(OUTPUT)_arm $(SWIFT_FILES) $(FRAMEWORKS) -F "$(SPARKLE_FRAMEWORK_PARENT)" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -target $(TARGET_ARM) -sdk $(XCODE_SDK)
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
	@mkdir -p $(APP_RESOURCES)/ThirdPartyLicenses
	@mkdir -p $(APP_FRAMEWORKS)
	@cp $(OUTPUT) $(APP_MACOS)/
	@ditto "$(SPARKLE_FRAMEWORK)" "$(APP_FRAMEWORKS)/Sparkle.framework"
	@cp Sources/App/Resources/Info.plist $(APP_CONTENTS)/
	@cp -R Sources/App/Resources/*.lproj $(APP_RESOURCES)/
	@cp -r Plugins/* $(APP_RESOURCES)/Plugins/
	@cp Sources/App/Resources/AppIcon.icns $(APP_RESOURCES)/
	@cp "$(SPARKLE_LICENSE)" "$(APP_RESOURCES)/ThirdPartyLicenses/Sparkle.txt"
	@bash Tools/verify_release_entitlements.sh --entitlements "$(APP_ENTITLEMENTS)" --info-plist Sources/App/Resources/Info.plist
	@echo "✍️ Ad-hoc signing $(APP_NAME).app and embedded Sparkle helpers..."
	@bash Tools/sign_sparkle_framework.sh --framework "$(APP_FRAMEWORKS)/Sparkle.framework"
	@codesign --force --entitlements "$(APP_ENTITLEMENTS)" --sign - $(APP_DIR)
	@codesign --verify --deep --strict --verbose=2 $(APP_DIR)
	@bash Tools/verify_release_entitlements.sh --entitlements "$(APP_ENTITLEMENTS)" --info-plist Sources/App/Resources/Info.plist --app "$(APP_DIR)"
	@bash Tools/verify_sparkle_update.sh --info-plist Sources/App/Resources/Info.plist --app "$(APP_DIR)" --require-ad-hoc
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
	@hdiutil verify $(BUILD_DIR)/$(DMG_NAME)
	@rm -rf $(BUILD_DIR)/dmg_stage
	@echo "✅ Ad-hoc community package created at $(BUILD_DIR)/$(DMG_NAME)"
	@echo "ℹ️  Community packages are not Apple-notarized; Sparkle updates are protected by Ed25519 signatures."

verify-release-version:
	bash Tools/verify_release_version.sh \
		--version "$(VERSION)" \
		--tags-at-head \
		--info-plist Sources/App/Resources/Info.plist \
		--artifact-plist "$(ARTIFACT_PLIST)"

verify-release-repository:
	bash Tools/verify_release_repository.sh --version "$(VERSION)"

verify-release-entitlements:
	bash Tools/verify_release_entitlements.sh \
		--entitlements "$(APP_ENTITLEMENTS)" \
		--info-plist Sources/App/Resources/Info.plist

verify-sparkle-update:
	bash Tools/verify_sparkle_update.sh --info-plist Sources/App/Resources/Info.plist

release: verify-release-repository verify-release-version verify-release-entitlements verify-sparkle-update
	@$(MAKE) package
	@$(MAKE) verify-release-version \
		VERSION="$(VERSION)" \
		ARTIFACT_PLIST="$(APP_CONTENTS)/Info.plist"
	@$(MAKE) generate-appcast VERSION="$(VERSION)" SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)"
	@echo "✅ Validated ad-hoc community release at $(BUILD_DIR)/$(DMG_NAME)"
	@echo "✅ Signed Sparkle feed created at $(APPCAST_PATH)"

generate-appcast: verify-release-repository verify-release-version verify-sparkle-update
	@test -f "$(BUILD_DIR)/$(DMG_NAME)" || { echo "❌ Missing release image: $(BUILD_DIR)/$(DMG_NAME)"; exit 1; }
	@test -x "$(SPARKLE_TOOLS)/generate_appcast" || { echo "❌ Sparkle generate_appcast tool is missing."; exit 1; }
	@bash Tools/verify_release_dmg.sh \
		--dmg "$(BUILD_DIR)/$(DMG_NAME)" \
		--version "$(VERSION)" \
		--info-plist Sources/App/Resources/Info.plist \
		--package-resolved Package.resolved
	@SOURCE_PUBLIC_KEY="$$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/App/Resources/Info.plist)"; \
	SIGNING_PUBLIC_KEY="$$($(SPARKLE_TOOLS)/generate_keys --account "$(SPARKLE_ACCOUNT)" -p)"; \
	[ "$${SIGNING_PUBLIC_KEY}" = "$${SOURCE_PUBLIC_KEY}" ] || { echo "❌ Sparkle signing key does not match SUPublicEDKey."; exit 1; }
	@rm -rf "$(APPCAST_DIR)"
	@mkdir -p "$(APPCAST_DIR)"
	@cp "$(BUILD_DIR)/$(DMG_NAME)" "$(APPCAST_DIR)/$(DMG_NAME)"
	@"$(SPARKLE_TOOLS)/generate_appcast" \
		--account "$(SPARKLE_ACCOUNT)" \
		--download-url-prefix "https://github.com/Wooden-Robot/OpenFire/releases/download/v$(VERSION)/" \
		--maximum-versions 1 \
		-o "$(abspath $(APPCAST_PATH))" \
		"$(APPCAST_DIR)"
	@bash Tools/verify_sparkle_appcast.sh \
		--appcast "$(APPCAST_PATH)" \
		--archive "$(BUILD_DIR)/$(DMG_NAME)" \
		--version "$(VERSION)" \
		--download-url "https://github.com/Wooden-Robot/OpenFire/releases/download/v$(VERSION)/$(DMG_NAME)" \
		--sign-update "$(SPARKLE_TOOLS)/sign_update" \
		--account "$(SPARKLE_ACCOUNT)"
	@rm -rf "$(APPCAST_DIR)"

publish-release-assets: verify-release-repository verify-release-version verify-sparkle-update
	@command -v gh >/dev/null || { echo "❌ GitHub CLI is required. Install and authenticate gh first."; exit 1; }
	@test -f "$(BUILD_DIR)/$(DMG_NAME)" || { echo "❌ Missing release image: $(BUILD_DIR)/$(DMG_NAME)"; exit 1; }
	@bash Tools/verify_github_draft_release.sh --version "$(VERSION)"
	@EXISTING="$$(gh api "repos/Wooden-Robot/OpenFire/releases/tags/v$(VERSION)" --hostname github.com --jq '.assets[].name')" || { echo "❌ Could not inspect existing draft assets."; exit 1; }; \
		! echo "$${EXISTING}" | grep -Fxq "$(DMG_NAME)" || { echo "❌ Draft already contains $(DMG_NAME); refusing to overwrite it."; exit 1; }; \
		! echo "$${EXISTING}" | grep -Fxq "appcast.xml" || { echo "❌ Draft already contains appcast.xml; refusing to overwrite it."; exit 1; }
	@bash Tools/verify_release_dmg.sh \
		--dmg "$(BUILD_DIR)/$(DMG_NAME)" \
		--version "$(VERSION)" \
		--info-plist Sources/App/Resources/Info.plist \
		--package-resolved Package.resolved
	@$(MAKE) generate-appcast VERSION="$(VERSION)" SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)"
	@gh release upload "v$(VERSION)" "$(BUILD_DIR)/$(DMG_NAME)#$(DMG_NAME)" "$(APPCAST_PATH)#appcast.xml" --repo "github.com/Wooden-Robot/OpenFire"
	@LOCAL_DMG_DIGEST="sha256:$$(shasum -a 256 "$(BUILD_DIR)/$(DMG_NAME)" | awk '{print $$1}')"; \
		LOCAL_APPCAST_DIGEST="sha256:$$(shasum -a 256 "$(APPCAST_PATH)" | awk '{print $$1}')"; \
		REMOTE_DMG_DIGEST="$$(gh api "repos/Wooden-Robot/OpenFire/releases/tags/v$(VERSION)" --hostname github.com --jq '.assets[] | select(.name == "$(DMG_NAME)") | .digest')"; \
		REMOTE_APPCAST_DIGEST="$$(gh api "repos/Wooden-Robot/OpenFire/releases/tags/v$(VERSION)" --hostname github.com --jq '.assets[] | select(.name == "appcast.xml") | .digest')"; \
		[ "$${REMOTE_DMG_DIGEST}" = "$${LOCAL_DMG_DIGEST}" ] || { echo "❌ Uploaded DMG digest mismatch; draft remains unpublished."; exit 1; }; \
		[ "$${REMOTE_APPCAST_DIGEST}" = "$${LOCAL_APPCAST_DIGEST}" ] || { echo "❌ Uploaded appcast digest mismatch; draft remains unpublished."; exit 1; }
	@bash Tools/verify_github_draft_release.sh --version "$(VERSION)"
	@gh release edit "v$(VERSION)" --draft=false --latest --repo "github.com/Wooden-Robot/OpenFire"
	@echo "✅ Verified both remote asset digests and published v$(VERSION)."

clean:
	rm -rf $(BUILD_DIR)

test: dependencies
	@echo "🧪 Running Tests..."
	bash Tests/verify_release_version_gate.sh
	bash Tests/verify_release_entitlements_gate.sh
	bash Tests/verify_sparkle_update_gate.sh
	bash Tests/verify_github_release_gate.sh
	bash Tests/verify_community_release_contract.sh
	swift test

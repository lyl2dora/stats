APP = Stats
BUNDLE_ID = zone.lyl.$(APP)

# Notarization credentials live outside the repo. Expected keys:
#   APPLE_API_KEY_ID, APPLE_API_ISSUER, APPLE_API_KEY (base64 of the App Store Connect .p8)
ENV_FILE ?= $(PWD)/../.env

# Materialises the .p8 into a private temp file that is removed when the recipe's shell exits.
# On CI the variables come straight from the environment and there is no env file to read.
ASC_KEY = if [ -f "$(ENV_FILE)" ]; then set -a; eval "$$(tr -d '\r' < "$(ENV_FILE)")"; set +a; fi ;\
	umask 077 ;\
	keyPath=$$(mktemp -t stats_asc_key) ;\
	trap 'rm -f "$$keyPath"' EXIT ;\
	printf '%s' "$$APPLE_API_KEY" | base64 --decode > "$$keyPath"
NOTARY_AUTH = --key "$$keyPath" --key-id "$$APPLE_API_KEY_ID" --issuer "$$APPLE_API_ISSUER"

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"
WIDGET_PATH = "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex"

.SILENT: archive notarize sign verify sign-dmg prepare-dmg prepare-dSYM clean next-version check history disk smc leveldb
.PHONY: build archive notarize sign verify sign-dmg prepare-dmg prepare-dSYM clean next-version check history open smc leveldb

build: clean next-version archive notarize sign verify prepare-dmg prepare-dSYM open

# --- MAIN WORLFLOW FUNCTIONS --- #

archive: clean
	-osascript -e 'display notification "Exporting application archive..." with title "Build the Stats"'
	echo "Exporting application archive..."

	xcodebuild \
  		-scheme $(APP) \
  		-destination 'platform=OS X,arch=arm64' \
  		-configuration Release archive \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		ARCHS=arm64 ONLY_ACTIVE_ARCH=NO

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
  		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		-exportPath $(BUILD_PATH)

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	-osascript -e 'display notification "Submitting app for notarization..." with title "Build the Stats"'
	echo "Submitting app for notarization..."

	$(ASC_KEY) ;\
	xcrun notarytool submit $(NOTARY_AUTH) --wait $(ZIP_PATH)

	echo "Stats successfully notarized"

sign:
	-osascript -e 'display notification "Stampling the Stats..." with title "Build the Stats"'
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	-osascript -e 'display notification "Stats successfully stapled" with title "Build the Stats"'
	echo "Stats successfully stapled"

verify:
	echo "Verifying widget extension..."

	if [ ! -d $(WIDGET_PATH) ]; then \
		echo "ERROR: widget extension is missing at $(WIDGET_PATH)"; \
		exit 1; \
	fi

	marketingVersion=$$(/usr/libexec/PlistBuddy -c "print :objects:9A141107229E721200D29793:buildSettings:MARKETING_VERSION" "$(PWD)/Stats.xcodeproj/project.pbxproj") ;\
	appShort=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(BUILD_PATH)/$(APP).app/Contents/Info.plist") ;\
	appBuild=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(BUILD_PATH)/$(APP).app/Contents/Info.plist") ;\
	widgetShort=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex/Contents/Info.plist") ;\
	widgetBuild=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(BUILD_PATH)/$(APP).app/Contents/PlugIns/WidgetsExtension.appex/Contents/Info.plist") ;\
	echo "Declared: $$marketingVersion" ;\
	echo "App:    $$appShort ($$appBuild)" ;\
	echo "Widget: $$widgetShort ($$widgetBuild)" ;\
	if [ "$$appShort" != "$$marketingVersion" ]; then \
		echo "ERROR: built app version ($$appShort) does not match the declared MARKETING_VERSION ($$marketingVersion)." ;\
		exit 1; \
	fi ;\
	if [ "$$appShort" != "$$widgetShort" ] || [ "$$appBuild" != "$$widgetBuild" ]; then \
		echo "ERROR: widget extension version ($$widgetShort/$$widgetBuild) does not match app version ($$appShort/$$appBuild)." ;\
		echo "PluginKit keys widgets on bundle-id + version; a stale version makes the widget disappear from the picker after update." ;\
		exit 1; \
	fi

	codesign --verify --strict $(WIDGET_PATH) || { echo "ERROR: widget extension code signature is invalid"; exit 1; }

	echo "Widget extension verified successfully"

prepare-dmg:
	if [ ! -d $(PWD)/create-dmg ]; then \
	    git clone https://github.com/create-dmg/create-dmg; \
	fi

	./create-dmg/create-dmg \
	    --volname $(APP) \
	    --background "./Stats/Supporting Files/background.png" \
	    --window-pos 200 120 \
	    --window-size 500 320 \
	    --icon-size 80 \
	    --icon "Stats.app" 125 175 \
	    --hide-extension "Stats.app" \
	    --app-drop-link 375 175 \
	    --no-internet-enable \
	    $(PWD)/$(APP).dmg \
	    $(APP_PATH)

	rm -rf ./create-dmg

# Signs, notarises and staples the disk image itself, so a manually downloaded
# image does not trip Gatekeeper on mount. The in-app updater does not need this:
# it mounts the image and validates the app inside it.
sign-dmg:
	echo "Signing the disk image..."
	codesign --force --sign "Developer ID Application" --timestamp $(PWD)/$(APP).dmg

	$(ASC_KEY) ;\
	xcrun notarytool submit $(NOTARY_AUTH) --wait $(PWD)/$(APP).dmg

	xcrun stapler staple $(PWD)/$(APP).dmg
	spctl -a -t open --context context:primary-signature -vv $(PWD)/$(APP).dmg
	echo "Disk image signed and notarized"

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd $(BUILD_PATH)/Stats.xcarchive/dSYMs && zip -r $(PWD)/dSYMs.zip .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf $(BUILD_PATH)
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Stats.dmg ]; then rm $(PWD)/Stats.dmg; fi;

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Stats/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Stats/Supporting Files/Info.plist" ;\

# usage: make check ID=<submission-uuid>
check:
	$(ASC_KEY) ;\
	xcrun notarytool log $(ID) $(NOTARY_AUTH)

history:
	$(ASC_KEY) ;\
	xcrun notarytool history $(NOTARY_AUTH)

open:
	-osascript -e 'display notification "Stats signed and ready for distribution" with title "Build the Stats"'
	echo "Opening working folder..."
	open $(PWD)

smc:
	$(MAKE) --directory=./smc
	open $(PWD)/smc

leveldb:
	if [ ! -d $(PWD)/leveldb-source ]; then \
		git clone --recurse-submodules https://github.com/google/leveldb.git leveldb-source; \
	fi
	mkdir -p $(PWD)/leveldb-source/build
	cd $(PWD)/leveldb-source/build && cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" -DCMAKE_BUILD_TYPE=Release .. && cmake --build .
	cp $(PWD)/leveldb-source/build/libleveldb.a $(PWD)/Kit/lldb/libleveldb.a
	rm -rf $(PWD)/leveldb-source
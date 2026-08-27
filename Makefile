.PHONY: gen fix-widget strings

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Fixes the Mac widget when it shows grey placeholder bars instead of tasks.
# Cause: LaunchServices resolves the widget extension to whichever registered
# copy has the highest CFBundleVersion. An Xcode build carries the bumped
# CURRENT_PROJECT_VERSION immediately, so it outranks the installed app and the
# widget host reads the wrong bundle. This unregisters every Veyrn copy except
# /Applications and re-registers that one. Xcode re-registers its build products
# on the next build; that is expected and harmless.
# Do NOT "killall chronod" — it deletes the cached archives and makes it worse.
fix-widget:
	@echo "Pruning stale Veyrn registrations…"
	@"$(LSREGISTER)" -dump 2>/dev/null \
		| sed -n 's/^[[:space:]]*path:[[:space:]]*//p' \
		| sed 's/ (0x[0-9a-fA-F]*)$$//' \
		| grep -i '/Veyrn\.app$$' | sort -u \
		| while IFS= read -r p; do \
			if [ "$$p" != "/Applications/Veyrn.app" ]; then \
				"$(LSREGISTER)" -u "$$p" >/dev/null 2>&1 && echo "  unregistered  $$p"; \
			fi; \
		done || true
	@"$(LSREGISTER)" -f /Applications/Veyrn.app
	@echo "  re-registered /Applications/Veyrn.app"
	@n=$$("$(LSREGISTER)" -dump 2>/dev/null | grep -ciE '^[[:space:]]*path:.*VikunjaWidgetExtension\.appex'); \
	if [ "$$n" -eq 1 ]; then \
		echo "✓ Exactly one bundle claims the widget extension — healthy."; \
		echo "  The widget refills on its own within ~2 minutes. Don't kill chronod."; \
	else \
		echo "⚠ $$n bundles still claim the widget extension (expected 1):"; \
		"$(LSREGISTER)" -dump 2>/dev/null | grep -iE '^[[:space:]]*path:.*VikunjaWidgetExtension\.appex'; \
	fi

gen:
	xcodegen generate
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n\t<key>com.apple.security.network.client</key>\n\t<true/>\n\t<key>com.apple.security.files.user-selected.read-write</key>\n\t<true/>\n\t<key>com.apple.security.files.downloads.read-write</key>\n\t<true/>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>com.apple.developer.icloud-container-identifiers</key>\n\t<array>\n\t\t<string>iCloud.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>com.apple.developer.icloud-services</key>\n\t<array>\n\t\t<string>CloudKit</string>\n\t</array>\n\t<key>com.apple.developer.aps-environment</key>\n\t<string>development</string>\n</dict>\n</plist>\n' \
		> VikunjaWidgetApp/VikunjaWidgetApp.entitlements
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n\t<key>com.apple.security.network.client</key>\n\t<true/>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n</dict>\n</plist>\n' \
		> VikunjaWidgetExtension/VikunjaWidgetExtension.entitlements
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>com.apple.developer.icloud-container-identifiers</key>\n\t<array>\n\t\t<string>iCloud.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>com.apple.developer.icloud-services</key>\n\t<array>\n\t\t<string>CloudKit</string>\n\t</array>\n\t<key>aps-environment</key>\n\t<string>development</string>\n</dict>\n</plist>\n' \
		> VikunjaWidgetApp/VikunjaWidgetAppIOS.entitlements
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n</dict>\n</plist>\n' \
		> VikunjaWidgetExtension/VikunjaWidgetExtensionIOS.entitlements
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n</dict>\n</plist>\n' \
		> VikunjaWidgetWatch/VikunjaWidgetWatch.entitlements
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$$(AppIdentifierPrefix)net.angstreich.VikunjaWidgetApp</string>\n\t</array>\n</dict>\n</plist>\n' \
		> VikunjaWidgetWatchExtension/VikunjaWidgetWatchExtension.entitlements
	@echo "✓ Entitlements restored (six files)"

# Refreshes VikunjaCore/Localizable.xcstrings from the strings actually used in
# source. Xcode does this itself when you build in the IDE; `xcodebuild` does
# not, so a CLI-only session leaves the table stale. Builds all three schemes
# first because the catalog is shared by every target — syncing from one
# platform's .stringsdata alone would mark the other platforms' strings stale.
strings:
	@set -e; \
	for s in VikunjaWidgetApp:platform=macOS \
	         VikunjaWidgetAppIOS:generic/platform=iOS \
	         VikunjaWidgetWatch:generic/platform=watchOS; do \
		scheme=$${s%%:*}; dest=$${s#*:}; \
		echo "Building $$scheme…"; \
		xcodebuild -project VikunjaWidget.xcodeproj -scheme "$$scheme" \
			-configuration Debug -destination "$$dest" build \
			CODE_SIGNING_ALLOWED=NO >/dev/null; \
	done; \
	intermediates=$$(xcodebuild -project VikunjaWidget.xcodeproj \
		-scheme VikunjaWidgetApp -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILD_DIR =/{print $$2; exit}' \
		| sed 's|/Build/Products|/Build/Intermediates.noindex|'); \
	args=$$(find "$$intermediates" -name '*.stringsdata' \
		-not -path '*/TelemetryDeck.build/*' \
		-exec printf -- '--stringsdata %s ' {} +); \
	xcrun xcstringstool sync VikunjaCore/Localizable.xcstrings $$args; \
	echo "✓ Catalog synced: $$(python3 -c \
		"import json;print(len(json.load(open('VikunjaCore/Localizable.xcstrings'))['strings']))") strings"

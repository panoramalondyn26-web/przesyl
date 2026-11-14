#!/usr/bin/env bash
# Przygotowuje projekt Przesył do zbudowania na danej platformie (android | macos | windows).
set -e
PLAT="$1"

mkdir -p lib
for f in main.dart transfer_service.dart; do
  if [ -f "$f" ]; then mv "$f" lib/; fi
done

flutter create --org com.przesyl --project-name przesyl --platforms="$PLAT" .
rm -f test/widget_test.dart
flutter pub add path_provider "file_picker:^10.0.0" "qr_flutter:^4.1.0" "mobile_scanner:^7.0.0"

if [ "$PLAT" = "android" ]; then
  MA=$(find android/app/src/main -name 'MainActivity.*' | head -n1)
  rm -f "$MA"
  cp MainActivity.kt "$(dirname "$MA")/MainActivity.kt"

  M=android/app/src/main/AndroidManifest.xml
  perl -0pi -e 's|<application|<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>\n    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>\n    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>\n    <uses-permission android:name="android.permission.CAMERA"/>\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n    <application android:usesCleartextTraffic="true" android:requestLegacyExternalStorage="true"|' "$M"
  perl -pi -e 's|android:label="przesyl"|android:label="Przesył"|' "$M"

  # Stały klucz podpisu – dzięki niemu kolejne wersje instalują się jako aktualizacja.
  if [ -f debug.keystore ]; then
    mkdir -p "$HOME/.android"
    cp debug.keystore "$HOME/.android/debug.keystore"
  fi
fi

if [ "$PLAT" = "macos" ]; then
  cp DebugProfile.entitlements macos/Runner/DebugProfile.entitlements
  cp Release.entitlements macos/Runner/Release.entitlements
  P=macos/Runner/Info.plist
  plutil -replace NSLocalNetworkUsageDescription -string "Przesył szuka innych urządzeń w Twojej sieci Wi-Fi, aby wymieniać pliki." "$P"
  plutil -replace NSCameraUsageDescription -string "Aparat służy do skanowania kodów QR." "$P"
  plutil -replace CFBundleDisplayName -string "Przesył" "$P"
fi

flutter pub get

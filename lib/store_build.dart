import 'package:flutter/services.dart' show appFlavor;

/// True in the Google Play build (`flutter build appbundle --flavor play`).
///
/// The Play build leaves out what Play policy doesn't allow this app to do
/// (see android/app/src/play/AndroidManifest.xml): VPN, uninstall protection,
/// "All files access", reading the call log, and downloads from sites whose
/// terms forbid it. The full build (`--flavor full`, sideloaded) keeps everything.
const bool kPlayStore = appFlavor == 'play';

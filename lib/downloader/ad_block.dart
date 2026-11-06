import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Ad blocking for the built-in browser: requests to known ad / pop-under /
/// tracking networks are blocked, and common ad boxes are hidden.
/// Not a complete list (ad networks change domains often), but it covers the
/// most common ones.

const adDomains = [
  // Google ads & trackers
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adservice.google.com',
  'pagead2.googlesyndication.com', 'google-analytics.com', 'googletagservices.com', 'adtrafficquality.google',
  // Pop-under / redirect networks
  'popads.net', 'popcash.net', 'propellerads.com', 'propellerclick.com', 'onclickads.net', 'onclkds.com',
  'adsterra.com', 'adsterratools.com', 'monetag.com', 'adcash.com', 'hilltopads.net', 'clickadu.com',
  'popunder.net', 'popmyads.com', 'admaven.com', 'ad-maven.com', 'richads.com', 'galaksion.com',
  'clickaine.com', 'pushground.com', 'evadav.com', 'rollerads.com', 'adstera.com', 'highperformanceformat.com',
  'highcpmgate.com', 'profitablegatecpm.com', 'effectiveratecpm.com', 'displaycontentnetwork.com',
  'tsyndicate.com', 'aclickads.com', 'pemsrv.com', 'ay267.com', 'a-ads.com',
  // Adult / aggressive networks often on free streaming sites
  'exoclick.com', 'exosrv.com', 'juicyads.com', 'trafficjunky.net', 'trafficstars.com', 'tsyndicate.com',
  'adxpansion.com', 'plugrush.com', 'ero-advertising.com',
  // Native / content ads
  'taboola.com', 'outbrain.com', 'mgid.com', 'revcontent.com', 'zergnet.com', 'adnxs.com', 'criteo.com',
  'criteo.net', 'pubmatic.com', 'rubiconproject.com', 'openx.net', 'smartadserver.com', 'amazon-adsystem.com',
  'adform.net', 'yieldmo.com', 'media.net', 'contextweb.com', 'sharethrough.com', 'teads.tv',
  'adcolony.com', 'applovin.com', 'unityads.unity3d.com', 'inmobi.com', 'vungle.com',
  // Trackers
  'scorecardresearch.com', 'quantserve.com', 'hotjar.com', 'mixpanel.com', 'adsrvr.org', 'bidswitch.net',
  'casalemedia.com', 'moatads.com', 'serving-sys.com', 'zedo.com', 'yandex.ru/ads', 'mc.yandex.ru',
];

/// URL paths that are almost always ad scripts / pop-under endpoints.
const adPathPatterns = [
  r'/afu\.php', r'/pop(under)?\.js', r'/popunder', r'/ads?/', r'/adserver', r'/banners?/',
  r'/prebid', r'/pagead/', r'/adsbygoogle',
];

/// Elements hidden on every page (typical ad containers).
const adSelectors = [
  'ins.adsbygoogle', '[id^="google_ads"]', '[id^="div-gpt-ad"]', 'iframe[src*="doubleclick"]',
  '[class*="ad-banner"]', '[class*="adsbox"]', '[id*="ad-container"]', '[class*="sponsored-ad"]',
  '.taboola', '#taboola', '.OUTBRAIN', '[data-ad-slot]', r'[id^="ad_"][id$="_wrapper"]',
];

String _escape(String s) => s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\/]'), (m) => '\\${m[0]}');

/// Host part of a domain list entry ("yandex.ru/ads" -> host + path).
final RegExp adUrlPattern = RegExp(
  '^https?://([a-z0-9-]+\\.)*(${adDomains.map(_escape).join('|')})([/:?#]|\$)'
  '|(${adPathPatterns.join('|')})',
  caseSensitive: false,
);

bool isAdUrl(String url) => adUrlPattern.hasMatch(url);

/// Content blockers for InAppWebView (one combined rule = fast on every request).
List<ContentBlocker> adContentBlockers() => [
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: adUrlPattern.pattern),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ),
      ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '.*'),
        action: ContentBlockerAction(
          type: ContentBlockerActionType.CSS_DISPLAY_NONE,
          selector: adSelectors.join(', '),
        ),
      ),
    ];

/// Registrable part of a host ("m.example.co.uk" -> "example.co.uk", "www.site.com" -> "site.com"),
/// to tell "same site" from "jumped to another site".
String siteOf(String host) {
  final parts = host.toLowerCase().split('.');
  if (parts.length <= 2) return parts.join('.');
  final twoLevel = {'co', 'com', 'org', 'net', 'gov', 'edu', 'ac'}.contains(parts[parts.length - 2]) &&
      parts.last.length == 2;
  return parts.sublist(parts.length - (twoLevel ? 3 : 2)).join('.');
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'api_client.dart';

/// Subscriptions: 1-month free trial after registering (given by the backend),
/// then Pro through Google Play (or the App Store). Every purchase is sent to
/// the backend, which checks it with Google/Apple and answers with the
/// entitlement: the app never decides on its own that someone has paid.
class SubscriptionService {
  SubscriptionService._();
  static final instance = SubscriptionService._();

  final _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// Free trial length from the backend (`/plans`).
  int trialDays = 30;

  /// Plans from the store, cheapest period first. Empty until [loadProducts].
  final products = ValueNotifier<List<ProductDetails>>(const []);

  /// True while a purchase or restore is being checked.
  final busy = ValueNotifier<bool>(false);

  /// Last purchase problem to show the user (cleared on the next attempt).
  final error = ValueNotifier<String?>(null);

  /// Text for the trial length: "1-month" for 30 days.
  String get trialLabel => trialDays == 30 ? '1-month' : '$trialDays-day';

  /// Starts listening for purchases. Call once at app start: Google Play can
  /// deliver a purchase later (pending payment, or the app closed mid-purchase).
  void init() {
    if (_sub != null || !(Platform.isAndroid || Platform.isIOS)) return;
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (Object e) {
      error.value = 'Purchase failed: $e';
      busy.value = false;
    });
  }

  /// Reads the plan IDs from the backend, then their prices from the store.
  Future<void> loadProducts() async {
    error.value = null;
    final ids = <String>{};
    try {
      final plans = await ApiClient.instance.publicJson('/api/v1/plans');
      trialDays = (plans['trialDays'] as num?)?.toInt() ?? trialDays;
      for (final p in (plans['products'] as List? ?? const [])) {
        ids.add((p as Map)['id'] as String);
      }
    } on ApiException catch (e) {
      error.value = e.message;
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (!await _iap.isAvailable()) {
      error.value = 'The Play Store is not available on this phone.';
      return;
    }
    final res = await _iap.queryProductDetails(ids);
    if (res.error != null) error.value = res.error!.message;
    // One entry per product (Android lists each offer of a subscription separately).
    final seen = <String>{};
    final list = res.productDetails.where((p) => seen.add(p.id)).toList()
      ..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
    products.value = list;
    if (list.isEmpty && error.value == null) {
      error.value = 'No plans found in the store yet (product IDs: ${ids.join(', ')}).';
    }
  }

  /// Opens the store's payment sheet. The user must be logged in.
  Future<void> buy(ProductDetails product) async {
    error.value = null;
    final api = ApiClient.instance;
    if (api.user.value?.accountToken == null) await api.refreshAccount();
    final token = api.user.value?.accountToken;
    if (token == null) {
      error.value = 'Please log in first.';
      return;
    }
    busy.value = true;
    try {
      // applicationUserName = Google Play's obfuscatedAccountId / Apple's appAccountToken.
      final started = await _iap.buyNonConsumable(
          purchaseParam: PurchaseParam(productDetails: product, applicationUserName: token));
      if (!started) busy.value = false;
    } catch (e) {
      busy.value = false;
      error.value = 'Could not start the purchase: $e';
    }
  }

  /// "Restore purchase": re-sends subscriptions bought earlier (new phone, reinstall).
  Future<void> restore() async {
    error.value = null;
    busy.value = true;
    try {
      await _iap.restorePurchases();
      // Nothing to restore = no stream event; stop the spinner after a moment.
      Future<void>.delayed(const Duration(seconds: 8), () => busy.value = false);
    } catch (e) {
      busy.value = false;
      error.value = 'Restore failed: $e';
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          busy.value = true;
        case PurchaseStatus.canceled:
          busy.value = false;
        case PurchaseStatus.error:
          busy.value = false;
          error.value = p.error?.message ?? 'Purchase failed';
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verify(p);
      }
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {/* the backend acknowledges Google purchases too */}
      }
    }
  }

  /// Backend checks the purchase with the store and returns the new entitlement.
  Future<void> _verify(PurchaseDetails p) async {
    final api = ApiClient.instance;
    try {
      final data = p.verificationData.serverVerificationData;
      final j = Platform.isIOS
          ? await api.json('POST', '/api/v1/purchases/apple', body: {'signedTransaction': data})
          : await api.json('POST', '/api/v1/purchases/google', body: {'purchaseToken': data});
      if (j['entitlement'] is Map) await api.setEntitlement(j['entitlement'] as Map<String, dynamic>);
    } on ApiException catch (e) {
      error.value = e.status == 401
          ? 'Log in to link this purchase to your account.'
          : 'Payment received, but it could not be checked yet: ${e.message}. Try "Restore purchase".';
    } finally {
      busy.value = false;
    }
  }
}

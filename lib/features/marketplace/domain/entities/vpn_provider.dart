enum ProviderTier { platinum, gold, standard }

enum ProviderCategory { privacy, streaming, gaming, business, budget, p2p }

class PricingInfo {
  final bool hasFree;
  final String? freeDescription;
  final String? freeDescriptionEn;
  final double monthlyPriceUsd;
  final String? trialDescription;
  final String? trialDescriptionEn;
  final String? priceLabel;
  final String? priceLabelEn;

  const PricingInfo({
    required this.hasFree,
    this.freeDescription,
    this.freeDescriptionEn,
    required this.monthlyPriceUsd,
    this.trialDescription,
    this.trialDescriptionEn,
    this.priceLabel,
    this.priceLabelEn,
  });

  String? freeDescriptionForLocale(String locale) =>
      locale == 'ru' ? freeDescription : freeDescriptionEn ?? freeDescription;

  String? trialDescriptionForLocale(String locale) => locale == 'ru'
      ? trialDescription
      : trialDescriptionEn ?? trialDescription;

  String? priceLabelForLocale(String locale) =>
      locale == 'ru' ? priceLabel : priceLabelEn ?? priceLabel;
}

class VpnProvider {
  final String id;
  final String name;
  final String tagline;
  final String? taglineEn;
  final String logoAsset;
  final String websiteUrl;
  final String referralUrl;
  final double rating;
  final int reviewCount;
  final ProviderTier tier;
  final List<ProviderCategory> categories;
  final List<String> protocols;
  final int serverCount;
  final int countryCount;
  final PricingInfo pricing;
  final List<String> features;
  final List<String>? featuresEn;
  final String shortDescription;
  final String? shortDescriptionEn;
  final bool supportsImport;
  final String? subscriptionUrlTemplate;
  final bool isOwn;

  const VpnProvider({
    required this.id,
    required this.name,
    this.tagline = '',
    this.taglineEn,
    this.logoAsset = '',
    required this.websiteUrl,
    required this.referralUrl,
    required this.rating,
    required this.reviewCount,
    required this.tier,
    required this.categories,
    required this.protocols,
    this.serverCount = 0,
    this.countryCount = 0,
    required this.pricing,
    required this.features,
    this.featuresEn,
    required this.shortDescription,
    this.shortDescriptionEn,
    this.supportsImport = false,
    this.subscriptionUrlTemplate,
    this.isOwn = false,
  });

  String taglineForLocale(String locale) =>
      locale == 'ru' ? tagline : taglineEn ?? tagline;

  List<String> featuresForLocale(String locale) =>
      locale == 'ru' ? features : featuresEn ?? features;

  String shortDescriptionForLocale(String locale) => locale == 'ru'
      ? shortDescription
      : shortDescriptionEn ?? shortDescription;
}

/// Static provider catalog.
/// Monetization: other VPN services pay a listing fee to appear here.
/// Tiers determine placement: platinum = top carousel, gold = featured badge, standard = regular.
class ProviderCatalog {
  static const _honeyvpn = VpnProvider(
    id: 'honeyvpn',
    name: 'Honey VPN',
    tagline: '🍯 Вкусные цены, сладкая скорость',
    taglineEn: '🍯 Sweet prices, sweet speeds',
    logoAsset: 'assets/images/honey_bear.jpg',
    websiteUrl: 'https://t.me/honeyvpnru_bot',
    referralUrl: 'https://t.me/honeyvpnru_bot',
    rating: 5.0,
    reviewCount: 736,
    tier: ProviderTier.platinum,
    categories: [ProviderCategory.privacy, ProviderCategory.streaming],
    protocols: ['VLESS', 'Hysteria2'],
    pricing: PricingInfo(
      hasFree: false,
      monthlyPriceUsd: 1,
      priceLabel: '90₽ / 30 дней',
      priceLabelEn: '90 RUB / 30 days',
      trialDescription: '3 дня бесплатно 🎁',
      trialDescriptionEn: '3 days free 🎁',
    ),
    features: [
      'Лучший VPN сервис',
      'Hysteria2 протокол',
      'VLESS протокол',
      'Все сервисы работают',
      'Быстрые серверы',
    ],
    featuresEn: [
      'The best VPN service',
      'Hysteria2 protocol',
      'VLESS protocol',
      'All services work',
      'Fast servers',
    ],
    shortDescription:
        '🍯 Honey VPN — вкусные цены, сладкая скорость. '
        'VPN-сервис на базе современных протоколов VLESS и Hysteria2. '
        'Лучший VPN для Wi-Fi · 3 дня бесплатно 🎁 · от 3 ₽/сутки · '
        'Все сервисы включая Gemini доступны.',
    shortDescriptionEn:
        '🍯 Honey VPN — sweet prices, sweet speeds. '
        'A VPN service using the modern VLESS and Hysteria2 protocols. '
        'The best VPN for Wi-Fi · 3 days free 🎁 · from 3 RUB/day · '
        'All services, including Gemini, are available.',
    supportsImport: true,
    subscriptionUrlTemplate: 'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH',
    isOwn: true,
  );

  static List<VpnProvider> get top3 => [_honeyvpn];
  static List<VpnProvider> get all => [_honeyvpn];
}

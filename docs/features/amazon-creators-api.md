# Amazon Creators API

## Overview

Amazon product data (buy links, prices, cover images) for music albums and games
comes from the **Amazon Creators API**. This replaced the Product Advertising API
(PA-API 5.0), which Amazon deprecated on 2026-04-30 and shut off on 2026-05-15.

The enrichment flow is the same for both domains: search Amazon, ask an AI task
which results genuinely match the item, then create `ExternalLink` records for
the matches.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  DataImporters::{Music::Album,Games::Game}::Providers::Amazon    │
│  queues a background job (never calls the API inline)            │
├──────────────────────────────────────────────────────────────────┤
│  {Music,Games}::AmazonProductEnrichmentJob   (Sidekiq, :serial)  │
├──────────────────────────────────────────────────────────────────┤
│  Services::{Music,Games}::AmazonProductService                   │
│  search -> AI match -> ExternalLinks (+ cover image for music)   │
├──────────────────────────────────────────────────────────────────┤
│  Services::Amazon::Client      │  Services::Amazon::Product      │
│  auth, marketplace, status     │  derived reads (lowest price)   │
├──────────────────────────────────────────────────────────────────┤
│  vacuum 5.x  ->  https://creatorsapi.amazon/catalog/v1           │
└──────────────────────────────────────────────────────────────────┘
```

`Services::Amazon::Client` is the only place that builds a `Vacuum` client. Both
domain services go through it, so credentials, marketplace and — most importantly
— the response status check live in exactly one place.

## Credentials

Registered at Associates Central → CreatorsAPI → Create Application → Create
Credential. **The credential secret is shown only once.**

| Variable | Purpose |
|---|---|
| `AMAZON_PRODUCT_API_CRED_ID` | OAuth2 client id (`amzn1.application-oa2-client…`) |
| `AMAZON_PRODUCT_API_SECRET` | OAuth2 client secret (`amzn1.oa2-cs.v1…`) |
| `AMAZON_PRODUCT_API_PARTNER_KEY` | Associates partner tag, embedded in every `detailPageURL` |

Amazon also assigns a **credential version** that selects the auth endpoint. This
app uses `3.1` (Login with Amazon, North America), set as
`Services::Amazon::Client::CREDENTIAL_VERSION`. Versions `2.x` use Amazon Cognito
instead; changing region means changing that constant.

Access tokens last one hour and are cached in `Rails.cache`, keyed on the
credential id. Sidekiq runs many jobs per process, so without the shared cache
every job would re-authenticate. Note the consequence: **rotating the secret
alone does not take effect until the cached token expires**, because the cache
key does not include it.

## Failing loudly

`Vacuum` returns a bare `HTTP::Response` and never raises. A failed call parses
into an error hash, so `dig("searchResult", "items")` yields `nil` — which reads
exactly like "Amazon matched nothing".

That is not hypothetical. It is how PA-API's shutdown went unnoticed: enrichment
returned "no products found" and reported success for roughly three months, with
a fully green test suite, because every test stubbed the HTTP layer.

`Services::Amazon::Client#search_items` therefore checks `response.status.success?`
and raises `Services::Amazon::Client::Error` on any non-2xx. It returns `[]` only
when Amazon genuinely matched nothing. **Do not "simplify" that check away.**

## Migrating from PA-API (reference)

| PA-API 5.0 | Creators API |
|---|---|
| AWS SigV4, access key + secret key | OAuth2 client credentials |
| `marketplace:` / `partner_tag:` at construction | required on **every** request |
| `marketplace: "US"` | `marketplace: "www.amazon.com"` |
| `response.to_h` | `response.parse` |
| `"SearchResult" => "Items"` | `"searchResult" => "items"` |
| `"ASIN"`, `"DetailPageURL"` | `"asin"`, `"detailPageURL"` |
| `ItemInfo.Title.DisplayValue` | `itemInfo.title.displayValue` |
| `Images.Primary.Large.URL` | `images.primary.large.url` |
| `BrowseNodeInfo.WebsiteSalesRank` | `browseNodeInfo.websiteSalesRank` |
| Resources `"ItemInfo.Title"` | Resources `"itemInfo.title"` |
| `Offers.Summaries[].LowestPrice` | **`offersV2.listings[]`** — see below |

Search parameters (`keywords`, `searchIndex`, `artist`, `title`) survived the
migration; vacuum camelizes any keyword argument and forwards it.

### Pricing changed shape

PA-API's `Offers.Summaries` handed back a pre-computed `LowestPrice` per
condition. OffersV2 has no summaries — only the individual listings — so the
equivalent figure is derived in `Services::Amazon::Product.lowest_price_cents`:
cheapest `New` listing, falling back to the cheapest listing of any condition.

It converts with `.round`, not `.to_i`. `(19.99 * 100).to_i` is `1998` in float
arithmetic; the PA-API-era code truncated prices by a cent this way.

## Testing

Domain service tests stub `Services::Amazon::Client.search_items` and pass Creators
API-shaped hashes. `test/lib/services/amazon/client_test.rb` covers the client
itself, including the non-2xx-must-raise case.

Tests that exercise the importer end to end (Sidekiq runs jobs inline) must stub
**two** hosts, because token exchange and search live on different ones:

```ruby
stub_request(:post, "https://api.amazon.com/auth/o2/token")
  .to_return(status: 200, body: '{"access_token": "test-token", "expires_in": 3600}',
    headers: {"Content-Type" => "application/json"})
stub_request(:post, "https://creatorsapi.amazon/catalog/v1/searchItems")
  .to_return(status: 200, body: '{"searchResult": {"items": []}}',
    headers: {"Content-Type" => "application/json"})
```

`WebMock::NetConnectNotAllowedError` descends from `Exception`, not
`StandardError`, so a missed stub blows straight past the services' `rescue => e`
and fails the test outright rather than degrading to a `failure` result.

## Known gaps

- **Books does not use Amazon yet.** There is no `Services::Books::AmazonProductService`
  and no Amazon provider in the books importer.
- Existing `external_links.metadata["amazon"]` payloads written before 2026-05
  hold PA-API-shaped (PascalCase) JSON. Nothing reads them at render time, so they
  were left as-is. `Services::BooksMigration::EditionTransformer` still reads the
  old shape deliberately — it parses stored legacy data, not live API responses.

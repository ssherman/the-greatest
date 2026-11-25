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

- **`Client.get_items` is unverified against the live API.** It was built from the gem's
  `get_items(marketplace:, partner_tag:, item_ids:, **params)` signature, and the gem ships no example
  response. It reads `itemsResult.items` by analogy with `searchResult.items`; that key has not been
  confirmed by a real call. It is used by `Services::Books::BookSubmissions::ResolveInput` (user-added
  books, Amazon links). Before that is relied on, make one real call for a known ASIN and confirm the key (a
  wrong key reads as "Amazon has no such product", the failure "Failing loudly" above warns about),
  then replace this note with the result. Also call one unknown ASIN: an empty answer is what
  `ResolveInput` expects; a non-2xx raises `Client::Error`, which it treats as "Amazon is down" and retries for
  an hour. To check, run this from a production console (it prints the status, the top-level keys and the
  titles, never headers or credentials; change the ASIN for the second call, e.g. `B0ZZZZZZZZ`). It uses none of the new code, only the existing client, so it can be run before the user-added books merge. Put it in a file and run it with `bin/rails runner`, since a console echoes every assignment:

  ```ruby
  amazon = Services::Amazon::Client.new
  response = amazon.send(:client).get_items(marketplace: Services::Amazon::Client::MARKETPLACE,
    partner_tag: amazon.send(:partner_tag), item_ids: ["0143039431"],
    resources: Services::Books::AmazonProductService::AMAZON_RESOURCES)
  body = response.parse
  puts response.status.code, body.keys.inspect
  puts body.values.flat_map { |part| part.is_a?(Hash) ? Array(part["items"]) : [] }.map { |item| item.dig("itemInfo", "title", "displayValue") }
  ```

  The key holding the items must be `itemsResult`. If it is another name, change it in
  `Client#get_items`.
- **Books enrichment runs through the book workflow's `amazon` step** (`Workflows::Books::Steps::Amazon`,
  wrapping `Services::Books::AmazonProductService`; see `enrichment-workflows.md`). Two callers plan
  a book run, and with it that step:
  - the importer's `Providers::Enrichment`, whenever an import with `enrich: true` runs its providers
    on a saved book. That covers new books, and existing ones imported with `item:` or
    `force_providers: true`;
  - `GoodreadsImports::PromoteRecords`, for each promoted book.

  The step is skipped (`no_authors`) for a book with no `book_authors` row, and gets seven attempts
  rather than three. `Books::AmazonProductEnrichmentJob` still backs the two rake tasks, which create
  no run: `books:amazon_enrich[id]` and `books:amazon_enrich_ranked`. Because `amazon_enriched_at` is
  stamped on the first pass, the ranked sweep is the only thing that retries a book whose step
  exhausted its attempts.

  Box sets and adaptations are filtered by `Services::Books::AmazonBookCheck` (see `data_importers.md`,
  Amazon (Async)).
- Existing `external_links.metadata["amazon"]` payloads written before 2026-05
  hold PA-API-shaped (PascalCase) JSON. Nothing reads them at render time, so they
  were left as-is. `Services::BooksMigration::EditionTransformer` still reads the
  old shape deliberately — it parses stored legacy data, not live API responses.

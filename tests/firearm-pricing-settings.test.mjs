import test from "node:test";
import assert from "node:assert/strict";
import { normalizeFirearmPricing } from "../supabase/functions/_shared/firearm-pricing.mjs";

test("accepts configurable shipping and tax rates by destination", () => {
  assert.deepEqual(normalizeFirearmPricing({
    shippingCents: 2495,
    taxRates: [
      { state: "ga", jurisdiction: "Houston County", rateBps: 800, taxShipping: true },
      { state: "FL", jurisdiction: "Miami-Dade County", rateBps: 700, taxShipping: false },
    ],
  }), {
    shippingCents: 2495,
    taxRates: [
      { state: "GA", jurisdiction: "Houston County", rateBps: 800, taxShipping: true },
      { state: "FL", jurisdiction: "Miami-Dade County", rateBps: 700, taxShipping: false },
    ],
  });
});

test("rejects invalid, duplicate, or unsupported destination tax settings", () => {
  assert.throws(() => normalizeFirearmPricing({ shippingCents: -1, taxRates: [] }), /shipping/);
  assert.throws(() => normalizeFirearmPricing({ shippingCents: 0, taxRates: [{ state: "XX", jurisdiction: "County", rateBps: 100, taxShipping: true }] }), /Check each/);
  assert.throws(() => normalizeFirearmPricing({ shippingCents: 0, taxRates: [
    { state: "GA", jurisdiction: "Houston County", rateBps: 800, taxShipping: true },
    { state: "ga", jurisdiction: "houston county", rateBps: 800, taxShipping: true },
  ] }), /only once/);
});

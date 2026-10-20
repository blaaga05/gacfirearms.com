import test from "node:test";
import assert from "node:assert/strict";
import {
  normalizeFirearmTaxLookup,
  normalizeTaxCloudQuote,
  taxCloudCartPayload,
} from "../supabase/functions/_shared/firearm-tax-lookup.mjs";

test("validates full destination and amount inputs", () => {
  assert.deepEqual(normalizeFirearmTaxLookup({
    line1: "  100 Main St ", line2: "Suite 2", city: "Kathleen", state: "ga", zip: "31047",
    firearmPriceCents: 229995, shippingCents: 3500,
  }), {
    destination: { line1: "100 Main St", line2: "Suite 2", city: "Kathleen", state: "GA", zip: "31047" },
    firearmPriceCents: 229995,
    shippingCents: 3500,
  });
  assert.throws(() => normalizeFirearmTaxLookup({ line1: "1 Main", city: "Macon", state: "GA", zip: "31201", firearmPriceCents: 0, shippingCents: 0 }), /invalid/);
  assert.throws(() => normalizeFirearmTaxLookup({ line1: "1 Main", city: "Macon", state: "GA", zip: "31201-1234x", firearmPriceCents: 100, shippingCents: 0 }), /street address/);
});

test("builds a TaxCloud cart for the receiving address and includes shipping as a separate line", () => {
  const result = taxCloudCartPayload({
    destination: { line1: "1 Main St", line2: "", city: "Macon", state: "GA", zip: "31201" },
    origin: { line1: "2 Shop Rd", city: "Kathleen", state: "GA", zip: "31047" },
    firearmPriceCents: 229995,
    shippingCents: 3500,
    cartId: "quote-123",
  });
  assert.equal(result.items[0].destination.zip, "31201");
  assert.equal(result.items[0].origin.state, "GA");
  assert.deepEqual(result.items[0].lineItems, [
    { index: 0, itemId: "firearm", price: 2299.95, quantity: 1, tic: 0 },
    { index: 1, itemId: "shipping", price: 35, quantity: 1, tic: 11010 },
  ]);
});

test("summarizes tax per item and fails closed on incomplete TaxCloud responses", () => {
  assert.deepEqual(normalizeTaxCloudQuote({ items: [{
    cartId: "quote-123", destination: { city: "Macon", state: "GA", zip: "31201" },
    lineItems: [
      { itemId: "firearm", tax: { rate: 0.08, amount: 183.99 } },
      { itemId: "shipping", tax: { rate: 0.08, amount: 2.80 } },
    ],
  }] }), {
    destination: { city: "Macon", state: "GA", zip: "31201" },
    rate: 0.08,
    firearmTaxCents: 18399,
    shippingTaxCents: 280,
    totalTaxCents: 18679,
    cartId: "quote-123",
  });
  assert.throws(() => normalizeTaxCloudQuote({ items: [{ lineItems: [] }] }), /incomplete estimate/);
});

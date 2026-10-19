import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const [schema, storefront, orderFunction, adminFunction] = await Promise.all([
  readFile(new URL("../database/firearms-catalog.sql", import.meta.url), "utf8"),
  readFile(new URL("../firearms-store.mjs", import.meta.url), "utf8"),
  readFile(new URL("../supabase/functions/gac-firearm-order-request/index.ts", import.meta.url), "utf8"),
  readFile(new URL("../supabase/functions/gac-firearms-admin/index.ts", import.meta.url), "utf8"),
]);

test("public catalog view contains no serial, private table access stays service-role only", async () => {
  assert.match(schema, /revoke all on public\.gac_firearm_inventory from anon, authenticated/i);
  assert.match(schema, /grant all on public\.gac_firearm_inventory to service_role/i);
  const photoMigration = await readFile(new URL("../database/firearm-listing-photos.sql", import.meta.url), "utf8");
  assert.match(photoMigration, /add column if not exists photo_path/i);
  assert.match(photoMigration, /security_invoker/i);
  assert.match(photoMigration, /photo_path/i);
  assert.match(storefront, /item\.photo_path/);
  const view = schema.split(/create or replace view public\.gac_firearm_catalog/i)[1].split(/create table if not exists public\.gac_firearm_order_requests/i)[0];
  assert.doesNotMatch(view, /serial_number|item_number|upc|sku|cost/i);
  assert.match(view, /where published and is_available and price_cents is not null/i);
});

test("public firearm request flow never collects payment details or creates a disposition", () => {
  assert.match(storefront, /gac_firearm_catalog/);
  assert.doesNotMatch(storefront, /serial_number|credit.?card|cardNumber|cvv/i);
  assert.doesNotMatch(orderFunction, /Authorize\.Net|chargeCustomerProfile|api\/Dispositions/i);
  assert.match(orderFunction, /gac_firearm_order_requests/);
  assert.match(orderFunction, /buyer_acknowledges_review/);
});

test("only the owner function reads serials and can publish a priced listing", () => {
  assert.match(adminFunction, /gac_is_owner/);
  assert.match(adminFunction, /serial_number/);
  assert.match(adminFunction, /Set a price before publishing/);
  assert.match(adminFunction, /FASTBOUND_ACCOUNT_NUMBER/);
});

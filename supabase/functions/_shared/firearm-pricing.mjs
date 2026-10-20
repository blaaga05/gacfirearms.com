const STATES = new Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC".split(" "));

export function normalizeFirearmPricing(input) {
  const shippingCents = input?.shippingCents;
  if (!Number.isInteger(shippingCents) || shippingCents < 0 || shippingCents > 1000000) {
    throw new Error("Enter shipping as an amount from $0 to $10,000.");
  }
  if (!Array.isArray(input?.taxRates) || input.taxRates.length > 500) {
    throw new Error("Tax rates must be a list of up to 500 destinations.");
  }
  const keys = new Set();
  const taxRates = [];
  for (const rate of input.taxRates) {
    if (!rate || typeof rate !== "object") throw new Error("A tax rate entry is invalid.");
    const state = typeof rate.state === "string" ? rate.state.trim().toUpperCase() : "";
    const jurisdiction = typeof rate.jurisdiction === "string" ? rate.jurisdiction.trim() : "";
    const rateBps = rate.rateBps;
    if (!STATES.has(state) || !jurisdiction || jurisdiction.length > 100 ||
        !Number.isInteger(rateBps) || rateBps < 0 || rateBps > 2500 ||
        typeof rate.taxShipping !== "boolean") {
      throw new Error("Check each state, county/jurisdiction, percentage, and shipping-tax setting.");
    }
    const key = state + "|" + jurisdiction.toLocaleLowerCase("en-US");
    if (keys.has(key)) throw new Error("Each state and jurisdiction can appear only once.");
    keys.add(key);
    taxRates.push({ state, jurisdiction, rateBps, taxShipping: rate.taxShipping });
  }
  return { shippingCents, taxRates };
}
